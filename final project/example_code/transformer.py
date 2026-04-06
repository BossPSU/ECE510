"""
Pure NumPy transformer language model.
Implements multi-head self-attention, positional encoding,
layer normalization, and full forward/backward pass.
"""

import numpy as np
import pickle
import os


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def softmax(x, axis=-1):
    x = x - np.max(x, axis=axis, keepdims=True)
    e = np.exp(x)
    return e / e.sum(axis=axis, keepdims=True)


def gelu(x):
    return 0.5 * x * (1.0 + np.tanh(np.sqrt(2.0 / np.pi) * (x + 0.044715 * x ** 3)))


def gelu_grad(x):
    tanh_arg = np.sqrt(2.0 / np.pi) * (x + 0.044715 * x ** 3)
    tanh_val = np.tanh(tanh_arg)
    dtanh = 1.0 - tanh_val ** 2
    inner_grad = np.sqrt(2.0 / np.pi) * (1.0 + 3 * 0.044715 * x ** 2)
    return 0.5 * (1.0 + tanh_val) + 0.5 * x * dtanh * inner_grad


# ---------------------------------------------------------------------------
# Parameter initialization
# ---------------------------------------------------------------------------

def init_params(vocab_size, seq_len, d_model, n_heads, d_ff, n_layers, seed=42):
    rng = np.random.default_rng(seed)
    scale = lambda fan_in: np.sqrt(2.0 / fan_in)

    params = {}

    # Token + positional embeddings
    params["tok_emb"] = rng.normal(0, 0.02, (vocab_size, d_model)).astype(np.float64)
    params["pos_emb"] = rng.normal(0, 0.02, (seq_len + 1, d_model)).astype(np.float64)

    for l in range(n_layers):
        p = f"l{l}"
        # Multi-head attention projections
        for name in ["Wq", "Wk", "Wv"]:
            params[f"{p}_{name}"] = rng.normal(0, scale(d_model), (d_model, d_model)).astype(np.float64)
        params[f"{p}_Wo"] = rng.normal(0, scale(d_model), (d_model, d_model)).astype(np.float64)

        # Attention biases
        for name in ["bq", "bk", "bv", "bo"]:
            params[f"{p}_{name}"] = np.zeros(d_model, dtype=np.float64)

        # Layer norms (attention + ff)
        params[f"{p}_ln1_g"] = np.ones(d_model, dtype=np.float64)
        params[f"{p}_ln1_b"] = np.zeros(d_model, dtype=np.float64)
        params[f"{p}_ln2_g"] = np.ones(d_model, dtype=np.float64)
        params[f"{p}_ln2_b"] = np.zeros(d_model, dtype=np.float64)

        # Feed-forward
        params[f"{p}_W1"] = rng.normal(0, scale(d_model), (d_model, d_ff)).astype(np.float64)
        params[f"{p}_b1"] = np.zeros(d_ff, dtype=np.float64)
        params[f"{p}_W2"] = rng.normal(0, scale(d_ff), (d_ff, d_model)).astype(np.float64)
        params[f"{p}_b2"] = np.zeros(d_model, dtype=np.float64)

    # Final layer norm + output projection
    params["ln_f_g"] = np.ones(d_model, dtype=np.float64)
    params["ln_f_b"] = np.zeros(d_model, dtype=np.float64)
    params["W_out"] = rng.normal(0, scale(d_model), (d_model, vocab_size)).astype(np.float64)
    params["b_out"] = np.zeros(vocab_size, dtype=np.float64)

    return params


# ---------------------------------------------------------------------------
# Layer norm (with backward)
# ---------------------------------------------------------------------------

def layer_norm_forward(x, g, b, eps=1e-5):
    mean = x.mean(axis=-1, keepdims=True)
    var = x.var(axis=-1, keepdims=True)
    x_hat = (x - mean) / np.sqrt(var + eps)
    out = g * x_hat + b
    cache = (x, x_hat, mean, var, g, eps)
    return out, cache


def layer_norm_backward(dout, cache):
    x, x_hat, mean, var, g, eps = cache
    N = x.shape[-1]
    dg = (dout * x_hat).sum(axis=tuple(range(dout.ndim - 1)))
    db = dout.sum(axis=tuple(range(dout.ndim - 1)))
    dx_hat = dout * g
    dvar = (-0.5 * dx_hat * (x - mean) * (var + eps) ** -1.5).sum(axis=-1, keepdims=True)
    dmean = (-dx_hat / np.sqrt(var + eps)).sum(axis=-1, keepdims=True) + dvar * (-2 * (x - mean)).mean(axis=-1, keepdims=True)
    dx = dx_hat / np.sqrt(var + eps) + dvar * 2 * (x - mean) / N + dmean / N
    return dx, dg, db


# ---------------------------------------------------------------------------
# Multi-head self-attention (with causal mask)
# ---------------------------------------------------------------------------

def mha_forward(x, Wq, Wk, Wv, Wo, bq, bk, bv, bo, n_heads):
    B, T, D = x.shape
    d_head = D // n_heads
    scale = 1.0 / np.sqrt(d_head)

    Q = x @ Wq + bq   # (B, T, D)
    K = x @ Wk + bk
    V = x @ Wv + bv

    # Split heads
    def split(t):
        return t.reshape(B, T, n_heads, d_head).transpose(0, 2, 1, 3)

    Q, K, V = split(Q), split(K), split(V)    # (B, H, T, d_head)

    scores = Q @ K.transpose(0, 1, 3, 2) * scale  # (B, H, T, T)

    # Causal mask
    mask = np.triu(np.ones((T, T), dtype=bool), k=1)
    scores[:, :, mask] = -1e9

    attn = softmax(scores, axis=-1)            # (B, H, T, T)
    ctx = attn @ V                             # (B, H, T, d_head)

    # Merge heads
    ctx = ctx.transpose(0, 2, 1, 3).reshape(B, T, D)
    out = ctx @ Wo + bo

    cache = (x, Q, K, V, attn, ctx, Wq, Wk, Wv, Wo, n_heads, scale)
    return out, cache


def mha_backward(dout, cache):
    x, Q, K, V, attn, ctx, Wq, Wk, Wv, Wo, n_heads, scale = cache
    B, T, D = x.shape
    d_head = D // n_heads

    dctx = dout @ Wo.T
    dWo = ctx.reshape(B * T, D).T @ dout.reshape(B * T, D)
    dbo = dout.sum(axis=(0, 1))

    # Merge -> split heads
    dctx = dctx.reshape(B, T, n_heads, d_head).transpose(0, 2, 1, 3)

    dV = attn.transpose(0, 1, 3, 2) @ dctx
    dattn = dctx @ V.transpose(0, 1, 3, 2)

    # Softmax backward
    dscores = attn * (dattn - (dattn * attn).sum(axis=-1, keepdims=True))
    dscores *= scale

    # Causal mask gradient is zero (already -inf, no grad flows)
    mask = np.triu(np.ones((T, T), dtype=bool), k=1)
    dscores[:, :, mask] = 0.0

    dQ = dscores @ K
    dK = dscores.transpose(0, 1, 3, 2) @ Q

    def merge(t):
        return t.transpose(0, 2, 1, 3).reshape(B, T, D)

    dQ, dK, dV = merge(dQ), merge(dK), merge(dV)

    dx = dQ @ Wq.T + dK @ Wk.T + dV @ Wv.T
    dWq = x.reshape(B * T, D).T @ dQ.reshape(B * T, D)
    dWk = x.reshape(B * T, D).T @ dK.reshape(B * T, D)
    dWv = x.reshape(B * T, D).T @ dV.reshape(B * T, D)
    dbq = dQ.sum(axis=(0, 1))
    dbk = dK.sum(axis=(0, 1))
    dbv = dV.sum(axis=(0, 1))

    return dx, dWq, dWk, dWv, dWo, dbq, dbk, dbv, dbo


# ---------------------------------------------------------------------------
# Feed-forward block
# ---------------------------------------------------------------------------

def ff_forward(x, W1, b1, W2, b2):
    h = x @ W1 + b1
    h_act = gelu(h)
    out = h_act @ W2 + b2
    cache = (x, h, h_act, W1, W2)
    return out, cache


def ff_backward(dout, cache):
    x, h, h_act, W1, W2 = cache
    B, T, _ = x.shape

    dh_act = dout @ W2.T
    dW2 = h_act.reshape(-1, h_act.shape[-1]).T @ dout.reshape(-1, dout.shape[-1])
    db2 = dout.sum(axis=(0, 1))

    dh = dh_act * gelu_grad(h)
    dW1 = x.reshape(-1, x.shape[-1]).T @ dh.reshape(-1, dh.shape[-1])
    db1 = dh.sum(axis=(0, 1))
    dx = dh @ W1.T

    return dx, dW1, db1, dW2, db2


# ---------------------------------------------------------------------------
# Full transformer forward
# ---------------------------------------------------------------------------

def forward(token_ids, params, config):
    n_layers = config["n_layers"]
    n_heads = config["n_heads"]
    B, T = token_ids.shape

    # pos_emb must cover T positions; init with seq_len+1 to be safe
    x = params["tok_emb"][token_ids] + params["pos_emb"][:T, :]

    caches = []
    for l in range(n_layers):
        p = f"l{l}"

        # Pre-norm attention
        xn, ln1_cache = layer_norm_forward(x, params[f"{p}_ln1_g"], params[f"{p}_ln1_b"])
        attn_out, attn_cache = mha_forward(
            xn,
            params[f"{p}_Wq"], params[f"{p}_Wk"], params[f"{p}_Wv"], params[f"{p}_Wo"],
            params[f"{p}_bq"], params[f"{p}_bk"], params[f"{p}_bv"], params[f"{p}_bo"],
            n_heads
        )
        x = x + attn_out

        # Pre-norm feed-forward
        xn2, ln2_cache = layer_norm_forward(x, params[f"{p}_ln2_g"], params[f"{p}_ln2_b"])
        ff_out, ff_cache = ff_forward(xn2, params[f"{p}_W1"], params[f"{p}_b1"],
                                      params[f"{p}_W2"], params[f"{p}_b2"])
        x = x + ff_out

        caches.append((ln1_cache, attn_cache, ln2_cache, ff_cache, xn, xn2, attn_out, ff_out))

    x_final, ln_f_cache = layer_norm_forward(x, params["ln_f_g"], params["ln_f_b"])
    logits = x_final @ params["W_out"] + params["b_out"]   # (B, T, vocab)

    return logits, (caches, ln_f_cache, x_final, x, token_ids)


# ---------------------------------------------------------------------------
# Loss: cross-entropy over shifted targets
# ---------------------------------------------------------------------------

def cross_entropy_loss(logits, token_ids):
    B, T, V = logits.shape
    targets = token_ids[:, 1:]          # (B, T-1)
    preds = logits[:, :-1, :]           # (B, T-1, V)

    probs = softmax(preds, axis=-1)
    log_probs = np.log(probs + 1e-9)

    loss = -log_probs[np.arange(B)[:, None], np.arange(T - 1)[None, :], targets].mean()

    dlogits = probs.copy()
    dlogits[np.arange(B)[:, None], np.arange(T - 1)[None, :], targets] -= 1.0
    dlogits /= (B * (T - 1))

    # Pad back to T
    dlogits_full = np.zeros((B, T, V))
    dlogits_full[:, :-1, :] = dlogits

    return loss, dlogits_full


# ---------------------------------------------------------------------------
# Backward pass
# ---------------------------------------------------------------------------

def backward(dlogits, all_caches, params, config):
    n_layers = config["n_layers"]
    caches, ln_f_cache, x_final, x_pre_final, token_ids = all_caches
    B, T = token_ids.shape

    grads = {k: np.zeros_like(v) for k, v in params.items()}

    # Output projection
    grads["W_out"] = x_final.reshape(B * T, -1).T @ dlogits.reshape(B * T, -1)
    grads["b_out"] = dlogits.sum(axis=(0, 1))
    dx = dlogits @ params["W_out"].T

    # Final layer norm
    dx, grads["ln_f_g"], grads["ln_f_b"] = layer_norm_backward(dx, ln_f_cache)

    for l in reversed(range(n_layers)):
        p = f"l{l}"
        ln1_cache, attn_cache, ln2_cache, ff_cache, xn, xn2, attn_out, ff_out = caches[l]

        # FF residual
        dff = dx.copy()
        dxn2, dW1, db1, dW2, db2 = ff_backward(dff, ff_cache)
        grads[f"{p}_W1"] += dW1
        grads[f"{p}_b1"] += db1
        grads[f"{p}_W2"] += dW2
        grads[f"{p}_b2"] += db2

        dxn2_ln, grads[f"{p}_ln2_g"], grads[f"{p}_ln2_b"] = layer_norm_backward(dxn2, ln2_cache)
        dx = dx + dxn2_ln

        # Attention residual
        dattn = dx.copy()
        dxn, dWq, dWk, dWv, dWo, dbq, dbk, dbv, dbo = mha_backward(dattn, attn_cache)
        grads[f"{p}_Wq"] += dWq
        grads[f"{p}_Wk"] += dWk
        grads[f"{p}_Wv"] += dWv
        grads[f"{p}_Wo"] += dWo
        grads[f"{p}_bq"] += dbq
        grads[f"{p}_bk"] += dbk
        grads[f"{p}_bv"] += dbv
        grads[f"{p}_bo"] += dbo

        dxn_ln, grads[f"{p}_ln1_g"], grads[f"{p}_ln1_b"] = layer_norm_backward(dxn, ln1_cache)
        dx = dx + dxn_ln

    # Embeddings
    np.add.at(grads["tok_emb"], token_ids, dx)
    grads["pos_emb"][:T] += dx.sum(axis=0)

    return grads


# ---------------------------------------------------------------------------
# Adam optimizer
# ---------------------------------------------------------------------------

class AdamOptimizer:
    def __init__(self, params, lr=1e-3, beta1=0.9, beta2=0.999, eps=1e-8, weight_decay=0.01):
        self.lr = lr
        self.beta1 = beta1
        self.beta2 = beta2
        self.eps = eps
        self.wd = weight_decay
        self.m = {k: np.zeros_like(v) for k, v in params.items()}
        self.v = {k: np.zeros_like(v) for k, v in params.items()}
        self.t = 0

    def step(self, params, grads):
        self.t += 1
        for k in params:
            g = grads[k]
            if self.wd > 0 and params[k].ndim >= 2:
                g = g + self.wd * params[k]
            self.m[k] = self.beta1 * self.m[k] + (1 - self.beta1) * g
            self.v[k] = self.beta2 * self.v[k] + (1 - self.beta2) * g ** 2
            m_hat = self.m[k] / (1 - self.beta1 ** self.t)
            v_hat = self.v[k] / (1 - self.beta2 ** self.t)
            params[k] -= self.lr * m_hat / (np.sqrt(v_hat) + self.eps)
        return params


# ---------------------------------------------------------------------------
# Tokenizer (character-level)
# ---------------------------------------------------------------------------

class CharTokenizer:
    def __init__(self, text):
        self.chars = sorted(set(text))
        self.vocab_size = len(self.chars)
        self.stoi = {c: i for i, c in enumerate(self.chars)}
        self.itos = {i: c for c, i in self.stoi.items()}

    def encode(self, text):
        return [self.stoi[c] for c in text if c in self.stoi]

    def decode(self, ids):
        return "".join(self.itos.get(i, "?") for i in ids)


# ---------------------------------------------------------------------------
# Training loop
# ---------------------------------------------------------------------------

def get_batch(data, batch_size, seq_len, rng):
    max_start = len(data) - seq_len - 1
    starts = rng.integers(0, max_start, size=batch_size)
    x = np.stack([data[s: s + seq_len + 1] for s in starts])
    return x


def train(text, config, n_steps=500, log_every=50, checkpoint_path=None):
    tokenizer = CharTokenizer(text)
    data = np.array(tokenizer.encode(text), dtype=np.int32)

    config["vocab_size"] = tokenizer.vocab_size
    params = init_params(
        vocab_size=tokenizer.vocab_size,
        seq_len=config["seq_len"],
        d_model=config["d_model"],
        n_heads=config["n_heads"],
        d_ff=config["d_ff"],
        n_layers=config["n_layers"],
        seed=config.get("seed", 42),
    )

    optimizer = AdamOptimizer(params, lr=config.get("lr", 1e-3))
    rng = np.random.default_rng(config.get("seed", 42))

    losses = []
    print(f"Vocab size: {tokenizer.vocab_size}  |  Data tokens: {len(data)}")
    print(f"Model config: {config}\n")

    for step in range(1, n_steps + 1):
        batch = get_batch(data, config["batch_size"], config["seq_len"], rng)
        logits, caches = forward(batch, params, config)
        loss, dlogits = cross_entropy_loss(logits, batch)
        grads = backward(dlogits, caches, params, config)
        params = optimizer.step(params, grads)
        losses.append(loss)

        if step % log_every == 0 or step == 1:
            print(f"Step {step:4d} | loss {loss:.4f}")

    if checkpoint_path:
        with open(checkpoint_path, "wb") as f:
            pickle.dump({"params": params, "config": config, "tokenizer": tokenizer}, f)
        print(f"\nCheckpoint saved to {checkpoint_path}")

    return params, tokenizer, losses


# ---------------------------------------------------------------------------
# Text generation (greedy / temperature sampling)
# ---------------------------------------------------------------------------

def generate(prompt, params, tokenizer, config, max_new=200, temperature=1.0, top_k=None):
    ids = tokenizer.encode(prompt)
    seq_len = config["seq_len"]

    for _ in range(max_new):
        ctx = np.array(ids[-seq_len:], dtype=np.int32)[None, :]
        logits, _ = forward(ctx, params, config)
        last_logits = logits[0, -1, :]   # (vocab,)

        if top_k is not None:
            threshold = np.sort(last_logits)[-top_k]
            last_logits = np.where(last_logits >= threshold, last_logits, -1e9)

        last_logits /= temperature
        probs = softmax(last_logits)
        next_id = np.random.choice(len(probs), p=probs)
        ids.append(int(next_id))

    return tokenizer.decode(ids)


# ---------------------------------------------------------------------------
# Load checkpoint and generate
# ---------------------------------------------------------------------------

def load_and_generate(checkpoint_path, prompt, max_new=200, temperature=0.8, top_k=40):
    with open(checkpoint_path, "rb") as f:
        ckpt = pickle.load(f)
    params = ckpt["params"]
    config = ckpt["config"]
    tokenizer = ckpt["tokenizer"]
    return generate(prompt, params, tokenizer, config, max_new, temperature, top_k)

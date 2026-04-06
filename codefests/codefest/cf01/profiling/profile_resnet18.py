import torch
from torchvision.models import resnet18
from torchinfo import summary

model = resnet18().float()

result = summary(
    model,
    input_size=(1, 3, 224, 224),
    dtypes=[torch.float32],
    depth=4,
    col_names=["input_size", "output_size", "num_params", "kernel_size", "mult_adds", "trainable"],
    verbose=0,
)

with open("resnet18_profile.txt", "w", encoding="utf-8") as f:
    f.write(str(result))
    f.write(f"\nTotal mult-adds (raw): {result.total_mult_adds:,}\n")

print("Profile saved to resnet18_profile.txt")

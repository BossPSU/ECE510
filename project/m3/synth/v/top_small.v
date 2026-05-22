module mac_pe (
	clk,
	rst_n,
	en,
	clear_acc,
	a_in,
	a_out,
	b_in,
	b_out,
	acc_out
);
	parameter signed [31:0] DATA_WIDTH = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire clear_acc;
	input wire signed [DATA_WIDTH - 1:0] a_in;
	output reg signed [DATA_WIDTH - 1:0] a_out;
	input wire signed [DATA_WIDTH - 1:0] b_in;
	output reg signed [DATA_WIDTH - 1:0] b_out;
	output wire signed [DATA_WIDTH - 1:0] acc_out;
	reg signed [DATA_WIDTH - 1:0] acc_r;
	wire signed [63:0] product;
	wire signed [DATA_WIDTH - 1:0] product_q;
	assign product = a_in * b_in;
	localparam signed [31:0] accel_pkg_FRAC_BITS = 16;
	assign product_q = product[47:accel_pkg_FRAC_BITS];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			a_out <= 1'sb0;
			b_out <= 1'sb0;
			acc_r <= 1'sb0;
		end
		else if (en) begin
			a_out <= a_in;
			b_out <= b_in;
			if (clear_acc)
				acc_r <= 1'sb0;
			else
				acc_r <= acc_r + product_q;
		end
	assign acc_out = acc_r;
endmodule
module systolic_array_64x64 (
	clk,
	rst_n,
	en,
	clear_acc,
	a_in,
	b_in,
	c_out
);
	localparam signed [31:0] accel_pkg_ARRAY_ROWS = 4;
	parameter signed [31:0] ROWS = accel_pkg_ARRAY_ROWS;
	localparam signed [31:0] accel_pkg_ARRAY_COLS = 4;
	parameter signed [31:0] COLS = accel_pkg_ARRAY_COLS;
	parameter signed [31:0] DATA_WIDTH = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire clear_acc;
	input wire signed [(ROWS * DATA_WIDTH) - 1:0] a_in;
	input wire signed [(COLS * DATA_WIDTH) - 1:0] b_in;
	output wire signed [((ROWS * COLS) * DATA_WIDTH) - 1:0] c_out;
	wire signed [DATA_WIDTH - 1:0] a_wire [0:ROWS - 1][0:COLS + 0];
	wire signed [DATA_WIDTH - 1:0] b_wire [0:ROWS + 0][0:COLS - 1];
	genvar _gv_r_1;
	genvar _gv_c_1;
	generate
		for (_gv_r_1 = 0; _gv_r_1 < ROWS; _gv_r_1 = _gv_r_1 + 1) begin : gen_a_in
			localparam r = _gv_r_1;
			assign a_wire[r][0] = a_in[((ROWS - 1) - r) * DATA_WIDTH+:DATA_WIDTH];
		end
		for (_gv_c_1 = 0; _gv_c_1 < COLS; _gv_c_1 = _gv_c_1 + 1) begin : gen_b_in
			localparam c = _gv_c_1;
			assign b_wire[0][c] = b_in[((COLS - 1) - c) * DATA_WIDTH+:DATA_WIDTH];
		end
		for (_gv_r_1 = 0; _gv_r_1 < ROWS; _gv_r_1 = _gv_r_1 + 1) begin : gen_row
			localparam r = _gv_r_1;
			for (_gv_c_1 = 0; _gv_c_1 < COLS; _gv_c_1 = _gv_c_1 + 1) begin : gen_col
				localparam c = _gv_c_1;
				mac_pe #(.DATA_WIDTH(DATA_WIDTH)) u_pe(
					.clk(clk),
					.rst_n(rst_n),
					.en(en),
					.clear_acc(clear_acc),
					.a_in(a_wire[r][c]),
					.a_out(a_wire[r][c + 1]),
					.b_in(b_wire[r][c]),
					.b_out(b_wire[r + 1][c]),
					.acc_out(c_out[((((ROWS - 1) - r) * COLS) + ((COLS - 1) - c)) * DATA_WIDTH+:DATA_WIDTH])
				);
			end
		end
	endgenerate
endmodule
module gelu_unit (
	clk,
	rst_n,
	en,
	x_in,
	in_valid,
	y_out,
	out_valid
);
	reg _sv2v_0;
	parameter signed [31:0] DATA_WIDTH = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire signed [DATA_WIDTH - 1:0] x_in;
	input wire in_valid;
	output reg signed [DATA_WIDTH - 1:0] y_out;
	output reg out_valid;
	localparam signed [31:0] Q_27 = 32'sh001b0000;
	localparam signed [31:0] Q_9 = 32'sh00090000;
	localparam signed [31:0] Q_GELU_X_MAX = 32'sh00100000;
	localparam signed [31:0] Q_GELU_X_MIN = 32'shfff00000;
	reg signed [31:0] x_for_poly;
	always @(*) begin
		if (_sv2v_0)
			;
		if (x_in > Q_GELU_X_MAX)
			x_for_poly = Q_GELU_X_MAX;
		else if (x_in < Q_GELU_X_MIN)
			x_for_poly = Q_GELU_X_MIN;
		else
			x_for_poly = x_in;
	end
	reg signed [31:0] s1_x;
	reg signed [31:0] s1_xp;
	reg signed [31:0] s1_x2;
	reg signed [31:0] s1_x3;
	reg s1_valid;
	localparam signed [31:0] accel_pkg_FRAC_BITS = 16;
	function automatic signed [31:0] accel_pkg_q_mul;
		input reg signed [31:0] a;
		input reg signed [31:0] b;
		reg signed [63:0] product;
		begin
			product = $signed(a) * $signed(b);
			accel_pkg_q_mul = product[47:accel_pkg_FRAC_BITS];
		end
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s1_valid <= 1'b0;
			s1_x <= 1'sb0;
			s1_xp <= 1'sb0;
			s1_x2 <= 1'sb0;
			s1_x3 <= 1'sb0;
		end
		else if (en) begin
			s1_valid <= in_valid;
			if (in_valid) begin
				s1_x <= x_in;
				s1_xp <= x_for_poly;
				s1_x2 <= accel_pkg_q_mul(x_for_poly, x_for_poly);
				s1_x3 <= accel_pkg_q_mul(accel_pkg_q_mul(x_for_poly, x_for_poly), x_for_poly);
			end
		end
	reg signed [31:0] s2_x;
	reg signed [31:0] s2_z;
	reg s2_valid;
	localparam signed [31:0] accel_pkg_Q_GELU_C1 = 32'sh00000b72;
	localparam signed [31:0] accel_pkg_Q_SQRT_2_PI = 32'sh0000cc38;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s2_valid <= 1'b0;
			s2_x <= 1'sb0;
			s2_z <= 1'sb0;
		end
		else if (en) begin
			s2_valid <= s1_valid;
			if (s1_valid) begin
				s2_x <= s1_x;
				s2_z <= accel_pkg_q_mul(accel_pkg_Q_SQRT_2_PI, s1_xp + accel_pkg_q_mul(accel_pkg_Q_GELU_C1, s1_x3));
			end
		end
	reg signed [31:0] s3_x;
	reg signed [31:0] s3_z;
	reg signed [31:0] s3_z2;
	reg s3_valid;
	reg s3_saturate_pos;
	reg s3_saturate_neg;
	localparam signed [31:0] accel_pkg_Q_SAT_NEG = 32'shfffc0000;
	localparam signed [31:0] accel_pkg_Q_SAT_POS = 32'sh00040000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s3_valid <= 1'b0;
			s3_x <= 1'sb0;
			s3_z <= 1'sb0;
			s3_z2 <= 1'sb0;
			s3_saturate_pos <= 1'b0;
			s3_saturate_neg <= 1'b0;
		end
		else if (en) begin
			s3_valid <= s2_valid;
			if (s2_valid) begin
				s3_x <= s2_x;
				if (s2_z > accel_pkg_Q_SAT_POS) begin
					s3_z <= accel_pkg_Q_SAT_POS;
					s3_saturate_pos <= 1'b1;
					s3_saturate_neg <= 1'b0;
				end
				else if (s2_z < accel_pkg_Q_SAT_NEG) begin
					s3_z <= accel_pkg_Q_SAT_NEG;
					s3_saturate_pos <= 1'b0;
					s3_saturate_neg <= 1'b1;
				end
				else begin
					s3_z <= s2_z;
					s3_saturate_pos <= 1'b0;
					s3_saturate_neg <= 1'b0;
				end
				s3_z2 <= accel_pkg_q_mul(s2_z, s2_z);
			end
		end
	reg signed [31:0] s4_x;
	reg signed [31:0] s4_num;
	reg signed [31:0] s4_den;
	reg s4_valid;
	reg s4_sat_pos;
	reg s4_sat_neg;
	localparam signed [31:0] accel_pkg_Q_ONE = 32'sh00010000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s4_valid <= 1'b0;
			s4_x <= 1'sb0;
			s4_num <= 1'sb0;
			s4_den <= accel_pkg_Q_ONE;
			s4_sat_pos <= 1'b0;
			s4_sat_neg <= 1'b0;
		end
		else if (en) begin
			s4_valid <= s3_valid;
			if (s3_valid) begin
				s4_x <= s3_x;
				s4_num <= accel_pkg_q_mul(s3_z, Q_27 + s3_z2);
				s4_den <= Q_27 + accel_pkg_q_mul(Q_9, s3_z2);
				s4_sat_pos <= s3_saturate_pos;
				s4_sat_neg <= s3_saturate_neg;
			end
		end
	reg signed [31:0] s5_x;
	reg signed [31:0] s5_tanh;
	reg s5_valid;
	localparam signed [31:0] accel_pkg_Q_ZERO = 32'sh00000000;
	function automatic signed [31:0] q_div;
		input reg signed [31:0] num;
		input reg signed [31:0] den;
		reg signed [63:0] num_ext;
		reg signed [63:0] result;
		reg [1:0] _sv2v_jump;
		begin
			_sv2v_jump = 2'b00;
			if (den == 0) begin
				q_div = accel_pkg_Q_ZERO;
				_sv2v_jump = 2'b11;
			end
			if (_sv2v_jump == 2'b00) begin
				num_ext = $signed({{16 {num[31]}}, num, 16'h0000});
				result = num_ext / $signed({{32 {den[31]}}, den});
				q_div = result[31:0];
				_sv2v_jump = 2'b11;
			end
		end
	endfunction
	localparam signed [31:0] accel_pkg_Q_NEG_ONE = 32'shffff0000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s5_valid <= 1'b0;
			s5_x <= 1'sb0;
			s5_tanh <= 1'sb0;
		end
		else if (en) begin
			s5_valid <= s4_valid;
			if (s4_valid) begin
				s5_x <= s4_x;
				if (s4_sat_pos)
					s5_tanh <= accel_pkg_Q_ONE;
				else if (s4_sat_neg)
					s5_tanh <= accel_pkg_Q_NEG_ONE;
				else
					s5_tanh <= q_div(s4_num, s4_den);
			end
		end
	localparam signed [31:0] accel_pkg_Q_HALF = 32'sh00008000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_valid <= 1'b0;
			y_out <= 1'sb0;
		end
		else if (en) begin
			out_valid <= s5_valid;
			if (s5_valid)
				y_out <= accel_pkg_q_mul(accel_pkg_Q_HALF, accel_pkg_q_mul(s5_x, accel_pkg_Q_ONE + s5_tanh));
		end
	initial _sv2v_0 = 0;
endmodule
module gelu_grad_unit (
	clk,
	rst_n,
	en,
	x_in,
	in_valid,
	grad_out,
	out_valid
);
	reg _sv2v_0;
	parameter signed [31:0] DATA_WIDTH = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire signed [DATA_WIDTH - 1:0] x_in;
	input wire in_valid;
	output reg signed [DATA_WIDTH - 1:0] grad_out;
	output reg out_valid;
	localparam signed [31:0] Q_27 = 32'sh001b0000;
	localparam signed [31:0] Q_9 = 32'sh00090000;
	localparam signed [31:0] Q_GELU_X_MAX = 32'sh00100000;
	localparam signed [31:0] Q_GELU_X_MIN = 32'shfff00000;
	reg signed [31:0] x_for_poly;
	always @(*) begin
		if (_sv2v_0)
			;
		if (x_in > Q_GELU_X_MAX)
			x_for_poly = Q_GELU_X_MAX;
		else if (x_in < Q_GELU_X_MIN)
			x_for_poly = Q_GELU_X_MIN;
		else
			x_for_poly = x_in;
	end
	localparam signed [31:0] accel_pkg_Q_ZERO = 32'sh00000000;
	function automatic signed [31:0] q_div;
		input reg signed [31:0] num;
		input reg signed [31:0] den;
		reg signed [63:0] num_ext;
		reg signed [63:0] result;
		reg [1:0] _sv2v_jump;
		begin
			_sv2v_jump = 2'b00;
			if (den == 0) begin
				q_div = accel_pkg_Q_ZERO;
				_sv2v_jump = 2'b11;
			end
			if (_sv2v_jump == 2'b00) begin
				num_ext = $signed({{16 {num[31]}}, num, 16'h0000});
				result = num_ext / $signed({{32 {den[31]}}, den});
				q_div = result[31:0];
				_sv2v_jump = 2'b11;
			end
		end
	endfunction
	reg signed [31:0] s1_x;
	reg signed [31:0] s1_xp;
	reg signed [31:0] s1_x2;
	reg signed [31:0] s1_x3;
	reg s1_valid;
	localparam signed [31:0] accel_pkg_FRAC_BITS = 16;
	function automatic signed [31:0] accel_pkg_q_mul;
		input reg signed [31:0] a;
		input reg signed [31:0] b;
		reg signed [63:0] product;
		begin
			product = $signed(a) * $signed(b);
			accel_pkg_q_mul = product[47:accel_pkg_FRAC_BITS];
		end
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s1_valid <= 1'b0;
			s1_x <= 1'sb0;
			s1_xp <= 1'sb0;
			s1_x2 <= 1'sb0;
			s1_x3 <= 1'sb0;
		end
		else if (en) begin
			s1_valid <= in_valid;
			if (in_valid) begin
				s1_x <= x_in;
				s1_xp <= x_for_poly;
				s1_x2 <= accel_pkg_q_mul(x_for_poly, x_for_poly);
				s1_x3 <= accel_pkg_q_mul(accel_pkg_q_mul(x_for_poly, x_for_poly), x_for_poly);
			end
		end
	reg signed [31:0] s2_x;
	reg signed [31:0] s2_z;
	reg signed [31:0] s2_inner_pre;
	reg s2_valid;
	localparam signed [31:0] accel_pkg_Q_GELU_C1 = 32'sh00000b72;
	localparam signed [31:0] accel_pkg_Q_GELU_C3 = 32'sh00002257;
	localparam signed [31:0] accel_pkg_Q_ONE = 32'sh00010000;
	localparam signed [31:0] accel_pkg_Q_SQRT_2_PI = 32'sh0000cc38;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s2_valid <= 1'b0;
			s2_x <= 1'sb0;
			s2_z <= 1'sb0;
			s2_inner_pre <= 1'sb0;
		end
		else if (en) begin
			s2_valid <= s1_valid;
			if (s1_valid) begin
				s2_x <= s1_x;
				s2_z <= accel_pkg_q_mul(accel_pkg_Q_SQRT_2_PI, s1_xp + accel_pkg_q_mul(accel_pkg_Q_GELU_C1, s1_x3));
				s2_inner_pre <= accel_pkg_Q_ONE + accel_pkg_q_mul(accel_pkg_Q_GELU_C3, s1_x2);
			end
		end
	reg signed [31:0] s3_x;
	reg signed [31:0] s3_z;
	reg signed [31:0] s3_z2;
	reg signed [31:0] s3_inner;
	reg s3_valid;
	reg s3_sat_pos;
	reg s3_sat_neg;
	localparam signed [31:0] accel_pkg_Q_SAT_NEG = 32'shfffc0000;
	localparam signed [31:0] accel_pkg_Q_SAT_POS = 32'sh00040000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s3_valid <= 1'b0;
			s3_x <= 1'sb0;
			s3_z <= 1'sb0;
			s3_z2 <= 1'sb0;
			s3_inner <= 1'sb0;
			s3_sat_pos <= 1'b0;
			s3_sat_neg <= 1'b0;
		end
		else if (en) begin
			s3_valid <= s2_valid;
			if (s2_valid) begin
				s3_x <= s2_x;
				s3_inner <= accel_pkg_q_mul(accel_pkg_Q_SQRT_2_PI, s2_inner_pre);
				if (s2_z > accel_pkg_Q_SAT_POS) begin
					s3_z <= accel_pkg_Q_SAT_POS;
					s3_sat_pos <= 1'b1;
					s3_sat_neg <= 1'b0;
				end
				else if (s2_z < accel_pkg_Q_SAT_NEG) begin
					s3_z <= accel_pkg_Q_SAT_NEG;
					s3_sat_pos <= 1'b0;
					s3_sat_neg <= 1'b1;
				end
				else begin
					s3_z <= s2_z;
					s3_sat_pos <= 1'b0;
					s3_sat_neg <= 1'b0;
				end
				s3_z2 <= accel_pkg_q_mul(s2_z, s2_z);
			end
		end
	reg signed [31:0] s4_x;
	reg signed [31:0] s4_num;
	reg signed [31:0] s4_den;
	reg signed [31:0] s4_inner;
	reg s4_valid;
	reg s4_sat_pos;
	reg s4_sat_neg;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s4_valid <= 1'b0;
			s4_x <= 1'sb0;
			s4_num <= 1'sb0;
			s4_den <= accel_pkg_Q_ONE;
			s4_inner <= 1'sb0;
			s4_sat_pos <= 1'b0;
			s4_sat_neg <= 1'b0;
		end
		else if (en) begin
			s4_valid <= s3_valid;
			if (s3_valid) begin
				s4_x <= s3_x;
				s4_inner <= s3_inner;
				s4_num <= accel_pkg_q_mul(s3_z, Q_27 + s3_z2);
				s4_den <= Q_27 + accel_pkg_q_mul(Q_9, s3_z2);
				s4_sat_pos <= s3_sat_pos;
				s4_sat_neg <= s3_sat_neg;
			end
		end
	reg signed [31:0] s5_x;
	reg signed [31:0] s5_tanh;
	reg signed [31:0] s5_dtanh;
	reg signed [31:0] s5_inner;
	reg s5_valid;
	localparam signed [31:0] accel_pkg_Q_NEG_ONE = 32'shffff0000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s5_valid <= 1'b0;
			s5_x <= 1'sb0;
			s5_tanh <= 1'sb0;
			s5_dtanh <= 1'sb0;
			s5_inner <= 1'sb0;
		end
		else if (en) begin
			s5_valid <= s4_valid;
			if (s4_valid) begin : sv2v_autoblock_1
				reg signed [31:0] tanh_val;
				s5_x <= s4_x;
				s5_inner <= s4_inner;
				if (s4_sat_pos)
					tanh_val = accel_pkg_Q_ONE;
				else if (s4_sat_neg)
					tanh_val = accel_pkg_Q_NEG_ONE;
				else
					tanh_val = q_div(s4_num, s4_den);
				s5_tanh <= tanh_val;
				s5_dtanh <= accel_pkg_Q_ONE - accel_pkg_q_mul(tanh_val, tanh_val);
			end
		end
	localparam signed [31:0] accel_pkg_Q_HALF = 32'sh00008000;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_valid <= 1'b0;
			grad_out <= 1'sb0;
		end
		else if (en) begin
			out_valid <= s5_valid;
			if (s5_valid) begin : sv2v_autoblock_2
				reg signed [31:0] term1;
				reg signed [31:0] term2;
				term1 = accel_pkg_q_mul(accel_pkg_Q_HALF, accel_pkg_Q_ONE + s5_tanh);
				term2 = accel_pkg_q_mul(accel_pkg_Q_HALF, accel_pkg_q_mul(s5_x, accel_pkg_q_mul(s5_dtanh, s5_inner)));
				grad_out <= term1 + term2;
			end
		end
	initial _sv2v_0 = 0;
endmodule
module softmax_unit (
	clk,
	rst_n,
	en,
	start,
	vec_len,
	scores_in,
	in_valid,
	probs_out,
	out_valid
);
	parameter signed [31:0] DATA_WIDTH = 32;
	parameter signed [31:0] VEC_LEN = 64;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire start;
	input wire [7:0] vec_len;
	input wire signed [(VEC_LEN * DATA_WIDTH) - 1:0] scores_in;
	input wire in_valid;
	output reg signed [(VEC_LEN * DATA_WIDTH) - 1:0] probs_out;
	output reg out_valid;
	localparam signed [31:0] accel_pkg_Q_ZERO = 32'sh00000000;
	function automatic signed [31:0] q_div;
		input reg signed [31:0] num;
		input reg signed [31:0] den;
		reg signed [63:0] num_ext;
		reg signed [63:0] result;
		reg [1:0] _sv2v_jump;
		begin
			_sv2v_jump = 2'b00;
			if (den == 0) begin
				q_div = accel_pkg_Q_ZERO;
				_sv2v_jump = 2'b11;
			end
			if (_sv2v_jump == 2'b00) begin
				num_ext = $signed({{16 {num[31]}}, num, 16'h0000});
				result = num_ext / $signed({{32 {den[31]}}, den});
				q_div = result[31:0];
				_sv2v_jump = 2'b11;
			end
		end
	endfunction
	reg s1_valid;
	reg s2_valid;
	reg s3_valid;
	reg [7:0] s1_len;
	reg [7:0] s2_len;
	reg [7:0] s3_len;
	reg signed [31:0] s1_scores [0:VEC_LEN - 1];
	reg signed [31:0] s1_max;
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s1_valid <= 1'b0;
			s1_max <= 1'sb0;
			s1_len <= 1'sb0;
			begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < VEC_LEN; i = i + 1)
					s1_scores[i] <= 1'sb0;
			end
		end
		else if (en && in_valid) begin : sv2v_autoblock_2
			reg signed [31:0] mx;
			s1_valid <= 1'b1;
			s1_len <= vec_len;
			mx = scores_in[(VEC_LEN - 1) * DATA_WIDTH+:DATA_WIDTH];
			s1_scores[0] <= scores_in[(VEC_LEN - 1) * DATA_WIDTH+:DATA_WIDTH];
			begin : sv2v_autoblock_3
				reg signed [31:0] i;
				for (i = 1; i < VEC_LEN; i = i + 1)
					begin
						if ((i < sv2v_cast_32_signed(vec_len)) && (scores_in[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] > mx))
							mx = scores_in[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH];
						s1_scores[i] <= scores_in[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH];
					end
			end
			s1_max <= mx;
		end
		else if (en)
			s1_valid <= 1'b0;
	reg signed [31:0] s2_exp [0:VEC_LEN - 1];
	localparam signed [31:0] accel_pkg_Q_ONE = 32'sh00010000;
	localparam signed [31:0] accel_pkg_FRAC_BITS = 16;
	function automatic signed [31:0] accel_pkg_q_mul;
		input reg signed [31:0] a;
		input reg signed [31:0] b;
		reg signed [63:0] product;
		begin
			product = $signed(a) * $signed(b);
			accel_pkg_q_mul = product[47:accel_pkg_FRAC_BITS];
		end
	endfunction
	function automatic signed [31:0] q_exp_approx;
		input reg signed [31:0] x;
		reg signed [31:0] y;
		reg signed [31:0] y2;
		reg signed [31:0] num;
		reg signed [31:0] den;
		reg signed [31:0] p;
		reg signed [31:0] p2;
		reg signed [31:0] p4;
		reg signed [63:0] num_ext;
		reg signed [63:0] q_full;
		localparam signed [31:0] Q_TWELVE = 32'sh000c0000;
		localparam signed [31:0] Q_SIX = 32'sh00060000;
		localparam signed [31:0] Q_EXP_FLOOR = 32'shfff00000;
		reg [1:0] _sv2v_jump;
		begin
			_sv2v_jump = 2'b00;
			if (x >= accel_pkg_Q_ZERO) begin
				q_exp_approx = accel_pkg_Q_ONE;
				_sv2v_jump = 2'b11;
			end
			if (_sv2v_jump == 2'b00) begin
				if (x < Q_EXP_FLOOR) begin
					q_exp_approx = accel_pkg_Q_ZERO;
					_sv2v_jump = 2'b11;
				end
				if (_sv2v_jump == 2'b00) begin
					y = x >>> 2;
					y2 = accel_pkg_q_mul(y, y);
					num = (Q_TWELVE + accel_pkg_q_mul(Q_SIX, y)) + y2;
					den = (Q_TWELVE - accel_pkg_q_mul(Q_SIX, y)) + y2;
					if (den <= 0) begin
						q_exp_approx = accel_pkg_Q_ZERO;
						_sv2v_jump = 2'b11;
					end
					if (_sv2v_jump == 2'b00) begin
						num_ext = $signed({{16 {num[31]}}, num, 16'h0000});
						q_full = num_ext / $signed({{32 {den[31]}}, den});
						if (q_full[31:0] < 0) begin
							q_exp_approx = accel_pkg_Q_ZERO;
							_sv2v_jump = 2'b11;
						end
						if (_sv2v_jump == 2'b00) begin
							p = q_full[31:0];
							p2 = accel_pkg_q_mul(p, p);
							p4 = accel_pkg_q_mul(p2, p2);
							q_exp_approx = p4;
							_sv2v_jump = 2'b11;
						end
					end
				end
			end
		end
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s2_valid <= 1'b0;
			s2_len <= 1'sb0;
			begin : sv2v_autoblock_4
				reg signed [31:0] i;
				for (i = 0; i < VEC_LEN; i = i + 1)
					s2_exp[i] <= 1'sb0;
			end
		end
		else if (en) begin
			s2_valid <= s1_valid;
			s2_len <= s1_len;
			if (s1_valid) begin : sv2v_autoblock_5
				reg signed [31:0] i;
				for (i = 0; i < VEC_LEN; i = i + 1)
					begin : sv2v_autoblock_6
						reg signed [31:0] diff;
						diff = s1_scores[i] - s1_max;
						if (i < sv2v_cast_32_signed(s1_len))
							s2_exp[i] <= q_exp_approx(diff);
						else
							s2_exp[i] <= 1'sb0;
					end
			end
		end
	reg signed [31:0] s3_exp [0:VEC_LEN - 1];
	reg signed [31:0] s3_sum;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s3_valid <= 1'b0;
			s3_sum <= 1'sb0;
			s3_len <= 1'sb0;
			begin : sv2v_autoblock_7
				reg signed [31:0] i;
				for (i = 0; i < VEC_LEN; i = i + 1)
					s3_exp[i] <= 1'sb0;
			end
		end
		else if (en) begin
			s3_valid <= s2_valid;
			s3_len <= s2_len;
			if (s2_valid) begin : sv2v_autoblock_8
				reg signed [31:0] acc;
				acc = 1'sb0;
				begin : sv2v_autoblock_9
					reg signed [31:0] i;
					for (i = 0; i < VEC_LEN; i = i + 1)
						begin
							if (i < sv2v_cast_32_signed(s2_len))
								acc = acc + s2_exp[i];
							s3_exp[i] <= s2_exp[i];
						end
				end
				s3_sum <= acc;
			end
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_valid <= 1'b0;
			begin : sv2v_autoblock_10
				reg signed [31:0] i;
				for (i = 0; i < VEC_LEN; i = i + 1)
					probs_out[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] <= 1'sb0;
			end
		end
		else if (en) begin
			out_valid <= s3_valid;
			if (s3_valid) begin : sv2v_autoblock_11
				reg signed [31:0] recip;
				if (s3_sum > 0) begin
					recip = q_div(accel_pkg_Q_ONE, s3_sum);
					begin : sv2v_autoblock_12
						reg signed [31:0] i;
						for (i = 0; i < VEC_LEN; i = i + 1)
							if (i < sv2v_cast_32_signed(s3_len))
								probs_out[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] <= accel_pkg_q_mul(s3_exp[i], recip);
							else
								probs_out[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] <= 1'sb0;
					end
				end
				else begin
					recip = (s3_len == 0 ? {32 {1'sb0}} : q_div(accel_pkg_Q_ONE, {8'd0, s3_len, 16'd0}));
					begin : sv2v_autoblock_13
						reg signed [31:0] i;
						for (i = 0; i < VEC_LEN; i = i + 1)
							if (i < sv2v_cast_32_signed(s3_len))
								probs_out[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] <= recip;
							else
								probs_out[((VEC_LEN - 1) - i) * DATA_WIDTH+:DATA_WIDTH] <= 1'sb0;
					end
				end
			end
		end
endmodule
module fused_postproc_unit (
	clk,
	rst_n,
	en,
	op_sel,
	data_in,
	in_valid,
	aux_in,
	data_out,
	out_valid
);
	reg _sv2v_0;
	parameter signed [31:0] DATA_WIDTH = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire [2:0] op_sel;
	input wire signed [DATA_WIDTH - 1:0] data_in;
	input wire in_valid;
	input wire signed [DATA_WIDTH - 1:0] aux_in;
	output reg signed [DATA_WIDTH - 1:0] data_out;
	output reg out_valid;
	wire signed [31:0] gelu_out;
	wire signed [31:0] gelu_grad_out;
	wire gelu_valid;
	wire gelu_grad_valid;
	gelu_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.x_in(data_in),
		.in_valid(in_valid && (op_sel == 3'd1)),
		.y_out(gelu_out),
		.out_valid(gelu_valid)
	);
	gelu_grad_unit #(.DATA_WIDTH(DATA_WIDTH)) u_gelu_grad(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.x_in(aux_in),
		.in_valid(in_valid && (op_sel == 3'd2)),
		.grad_out(gelu_grad_out),
		.out_valid(gelu_grad_valid)
	);
	localparam signed [31:0] GRAD_DELAY = 6;
	reg signed [31:0] data_delay [0:5];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < GRAD_DELAY; i = i + 1)
				data_delay[i] <= 1'sb0;
		end
		else if (en) begin
			data_delay[0] <= data_in;
			begin : sv2v_autoblock_2
				reg signed [31:0] i;
				for (i = 1; i < GRAD_DELAY; i = i + 1)
					data_delay[i] <= data_delay[i - 1];
			end
		end
	localparam signed [31:0] accel_pkg_FRAC_BITS = 16;
	function automatic signed [31:0] accel_pkg_q_mul;
		input reg signed [31:0] a;
		input reg signed [31:0] b;
		reg signed [63:0] product;
		begin
			product = $signed(a) * $signed(b);
			accel_pkg_q_mul = product[47:accel_pkg_FRAC_BITS];
		end
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		data_out = 1'sb0;
		out_valid = 1'b0;
		if (gelu_valid) begin
			data_out = gelu_out;
			out_valid = 1'b1;
		end
		else if (gelu_grad_valid) begin
			data_out = accel_pkg_q_mul(data_delay[5], gelu_grad_out);
			out_valid = 1'b1;
		end
		else if (in_valid && ((op_sel == 3'd0) || (op_sel == 3'd4))) begin
			data_out = data_in;
			out_valid = 1'b1;
		end
	end
	initial _sv2v_0 = 0;
endmodule
module sram_bank (
	clk,
	req,
	we,
	addr,
	wdata,
	rdata,
	rvalid
);
	parameter signed [31:0] DATA_WIDTH = 32;
	localparam signed [31:0] accel_pkg_SRAM_DEPTH = 64;
	parameter signed [31:0] DEPTH = accel_pkg_SRAM_DEPTH;
	localparam signed [31:0] accel_pkg_SRAM_ADDR_W = 6;
	parameter signed [31:0] ADDR_WIDTH = accel_pkg_SRAM_ADDR_W;
	input wire clk;
	input wire req;
	input wire we;
	input wire [ADDR_WIDTH - 1:0] addr;
	input wire [DATA_WIDTH - 1:0] wdata;
	output reg [DATA_WIDTH - 1:0] rdata;
	output reg rvalid;
	reg [DATA_WIDTH - 1:0] mem [0:DEPTH - 1];
	always @(posedge clk) begin
		rvalid <= 1'b0;
		if (req) begin
			if (we)
				mem[addr] <= wdata;
			else begin
				rdata <= mem[addr];
				rvalid <= 1'b1;
			end
		end
	end
endmodule
module scratchpad_ctrl (
	clk,
	rst_n,
	a_req,
	a_addr,
	a_rdata,
	a_rvalid,
	b_req,
	b_we,
	b_addr,
	b_wdata,
	c_req,
	c_we,
	c_addr,
	c_wdata,
	c_rdata,
	c_rvalid
);
	reg _sv2v_0;
	parameter signed [31:0] DATA_WIDTH = 32;
	localparam signed [31:0] accel_pkg_SRAM_BANKS = 2;
	parameter signed [31:0] NUM_BANKS = accel_pkg_SRAM_BANKS;
	localparam signed [31:0] accel_pkg_SRAM_DEPTH = 64;
	parameter signed [31:0] BANK_DEPTH = accel_pkg_SRAM_DEPTH;
	parameter signed [31:0] ADDR_WIDTH = 16;
	input wire clk;
	input wire rst_n;
	input wire a_req;
	input wire [ADDR_WIDTH - 1:0] a_addr;
	output wire [DATA_WIDTH - 1:0] a_rdata;
	output wire a_rvalid;
	input wire b_req;
	input wire b_we;
	input wire [ADDR_WIDTH - 1:0] b_addr;
	input wire [DATA_WIDTH - 1:0] b_wdata;
	input wire c_req;
	input wire c_we;
	input wire [ADDR_WIDTH - 1:0] c_addr;
	input wire [DATA_WIDTH - 1:0] c_wdata;
	output wire [DATA_WIDTH - 1:0] c_rdata;
	output wire c_rvalid;
	localparam signed [31:0] BANK_ADDR_W = $clog2(BANK_DEPTH);
	localparam signed [31:0] BANK_SEL_W = $clog2(NUM_BANKS);
	wire [BANK_SEL_W - 1:0] a_bank = a_addr[BANK_SEL_W - 1:0];
	wire [BANK_ADDR_W - 1:0] a_bank_addr = a_addr[BANK_SEL_W+:BANK_ADDR_W];
	wire [BANK_SEL_W - 1:0] b_bank = b_addr[BANK_SEL_W - 1:0];
	wire [BANK_ADDR_W - 1:0] b_bank_addr = b_addr[BANK_SEL_W+:BANK_ADDR_W];
	wire [BANK_SEL_W - 1:0] c_bank = c_addr[BANK_SEL_W - 1:0];
	wire [BANK_ADDR_W - 1:0] c_bank_addr = c_addr[BANK_SEL_W+:BANK_ADDR_W];
	reg bank_req [0:NUM_BANKS - 1];
	reg bank_we [0:NUM_BANKS - 1];
	reg [BANK_ADDR_W - 1:0] bank_addr [0:NUM_BANKS - 1];
	reg [DATA_WIDTH - 1:0] bank_wdata [0:NUM_BANKS - 1];
	wire [DATA_WIDTH - 1:0] bank_rdata [0:NUM_BANKS - 1];
	wire bank_rvalid [0:NUM_BANKS - 1];
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < NUM_BANKS; _gv_i_1 = _gv_i_1 + 1) begin : gen_bank
			localparam i = _gv_i_1;
			sram_bank #(
				.DATA_WIDTH(DATA_WIDTH),
				.DEPTH(BANK_DEPTH),
				.ADDR_WIDTH(BANK_ADDR_W)
			) u_bank(
				.clk(clk),
				.req(bank_req[i]),
				.we(bank_we[i]),
				.addr(bank_addr[i]),
				.wdata(bank_wdata[i]),
				.rdata(bank_rdata[i]),
				.rvalid(bank_rvalid[i])
			);
		end
	endgenerate
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] b;
			for (b = 0; b < NUM_BANKS; b = b + 1)
				begin
					bank_req[b] = 1'b0;
					bank_we[b] = 1'b0;
					bank_addr[b] = 1'sb0;
					bank_wdata[b] = 1'sb0;
					if (a_req && (sv2v_cast_32_signed(a_bank) == b)) begin
						bank_req[b] = 1'b1;
						bank_we[b] = 1'b0;
						bank_addr[b] = a_bank_addr;
					end
					else if (b_req && (sv2v_cast_32_signed(b_bank) == b)) begin
						bank_req[b] = 1'b1;
						bank_we[b] = b_we;
						bank_addr[b] = b_bank_addr;
						bank_wdata[b] = b_wdata;
					end
					else if (c_req && (sv2v_cast_32_signed(c_bank) == b)) begin
						bank_req[b] = 1'b1;
						bank_we[b] = c_we;
						bank_addr[b] = c_bank_addr;
						bank_wdata[b] = c_wdata;
					end
				end
		end
	end
	assign a_rdata = bank_rdata[a_bank];
	assign a_rvalid = bank_rvalid[a_bank];
	assign c_rdata = bank_rdata[c_bank];
	assign c_rvalid = bank_rvalid[c_bank];
	initial _sv2v_0 = 0;
endmodule
module dma_engine (
	clk,
	rst_n,
	host_wr_valid,
	host_wr_addr,
	host_wr_data,
	host_wr_ready,
	host_rd_req,
	host_rd_addr,
	host_rd_data,
	host_rd_valid,
	sram_req,
	sram_we,
	sram_addr,
	sram_wdata,
	sram_rdata,
	sram_rvalid
);
	parameter signed [31:0] DATA_WIDTH = 32;
	parameter signed [31:0] ADDR_WIDTH = 16;
	input wire clk;
	input wire rst_n;
	input wire host_wr_valid;
	input wire [ADDR_WIDTH - 1:0] host_wr_addr;
	input wire [DATA_WIDTH - 1:0] host_wr_data;
	output wire host_wr_ready;
	input wire host_rd_req;
	input wire [ADDR_WIDTH - 1:0] host_rd_addr;
	output wire [DATA_WIDTH - 1:0] host_rd_data;
	output wire host_rd_valid;
	output reg sram_req;
	output reg sram_we;
	output reg [ADDR_WIDTH - 1:0] sram_addr;
	output reg [DATA_WIDTH - 1:0] sram_wdata;
	input wire [DATA_WIDTH - 1:0] sram_rdata;
	input wire sram_rvalid;
	assign host_wr_ready = 1'b1;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			sram_req <= 1'b0;
			sram_we <= 1'b0;
		end
		else if (host_wr_valid) begin
			sram_req <= 1'b1;
			sram_we <= 1'b1;
			sram_addr <= host_wr_addr;
			sram_wdata <= host_wr_data;
		end
		else if (host_rd_req) begin
			sram_req <= 1'b1;
			sram_we <= 1'b0;
			sram_addr <= host_rd_addr;
		end
		else begin
			sram_req <= 1'b0;
			sram_we <= 1'b0;
		end
	assign host_rd_data = sram_rdata;
	assign host_rd_valid = sram_rvalid;
endmodule
module tile_buffer (
	clk,
	rst_n,
	wr_en,
	wr_idx,
	wr_data,
	rd_row,
	rd_col,
	rd_data,
	rd_lin_idx,
	rd_lin_data,
	mp_rd_row,
	mp_rd_col,
	mp_rd_data
);
	parameter signed [31:0] DATA_WIDTH = 32;
	parameter signed [31:0] TILE_DIM = 64;
	parameter signed [31:0] NUM_RD_PORTS = 1;
	input wire clk;
	input wire rst_n;
	input wire wr_en;
	input wire [11:0] wr_idx;
	input wire signed [DATA_WIDTH - 1:0] wr_data;
	input wire [7:0] rd_row;
	input wire [7:0] rd_col;
	output wire signed [DATA_WIDTH - 1:0] rd_data;
	input wire [11:0] rd_lin_idx;
	output wire signed [DATA_WIDTH - 1:0] rd_lin_data;
	input wire [(NUM_RD_PORTS * 8) - 1:0] mp_rd_row;
	input wire [(NUM_RD_PORTS * 8) - 1:0] mp_rd_col;
	output wire signed [(NUM_RD_PORTS * DATA_WIDTH) - 1:0] mp_rd_data;
	reg signed [DATA_WIDTH - 1:0] mem [0:TILE_DIM - 1][0:TILE_DIM - 1];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin : sv2v_autoblock_1
			reg signed [31:0] i;
			for (i = 0; i < TILE_DIM; i = i + 1)
				begin : sv2v_autoblock_2
					reg signed [31:0] j;
					for (j = 0; j < TILE_DIM; j = j + 1)
						mem[i][j] <= 1'sb0;
				end
		end
		else if (wr_en)
			mem[wr_idx[11:6]][wr_idx[5:0]] <= wr_data;
	assign rd_data = mem[rd_row[5:0]][rd_col[5:0]];
	assign rd_lin_data = mem[rd_lin_idx[11:6]][rd_lin_idx[5:0]];
	genvar _gv_p_1;
	generate
		for (_gv_p_1 = 0; _gv_p_1 < NUM_RD_PORTS; _gv_p_1 = _gv_p_1 + 1) begin : gen_rd_port
			localparam p = _gv_p_1;
			assign mp_rd_data[((NUM_RD_PORTS - 1) - p) * DATA_WIDTH+:DATA_WIDTH] = mem[mp_rd_row[(((NUM_RD_PORTS - 1) - p) * 8) + 5-:6]][mp_rd_col[(((NUM_RD_PORTS - 1) - p) * 8) + 5-:6]];
		end
	endgenerate
endmodule
module stream_pipeline (
	clk,
	rst_n,
	start,
	done,
	tile_m,
	tile_n,
	tile_k,
	op_sel,
	a_rd_row,
	a_rd_col,
	a_rd_data,
	b_rd_row,
	b_rd_col,
	b_rd_data,
	aux_rd_row,
	aux_rd_col,
	aux_rd_data,
	out_wr_en,
	out_wr_idx,
	out_wr_data,
	running_o
);
	parameter signed [31:0] DATA_WIDTH = 32;
	localparam signed [31:0] accel_pkg_ARRAY_ROWS = 4;
	parameter signed [31:0] ARRAY_DIM = accel_pkg_ARRAY_ROWS;
	input wire clk;
	input wire rst_n;
	input wire start;
	output reg done;
	input wire [7:0] tile_m;
	input wire [7:0] tile_n;
	input wire [7:0] tile_k;
	input wire [2:0] op_sel;
	output wire [(ARRAY_DIM * 8) - 1:0] a_rd_row;
	output wire [(ARRAY_DIM * 8) - 1:0] a_rd_col;
	input wire signed [(ARRAY_DIM * DATA_WIDTH) - 1:0] a_rd_data;
	output wire [(ARRAY_DIM * 8) - 1:0] b_rd_row;
	output wire [(ARRAY_DIM * 8) - 1:0] b_rd_col;
	input wire signed [(ARRAY_DIM * DATA_WIDTH) - 1:0] b_rd_data;
	output wire [7:0] aux_rd_row;
	output wire [7:0] aux_rd_col;
	input wire signed [DATA_WIDTH - 1:0] aux_rd_data;
	output wire out_wr_en;
	output wire [11:0] out_wr_idx;
	output wire signed [DATA_WIDTH - 1:0] out_wr_data;
	output wire running_o;
	reg [15:0] cycle_cnt;
	reg running;
	assign running_o = running;
	localparam signed [31:0] DRAIN_CYCLES = 4;
	localparam signed [31:0] FUSED_DEPTH = 7;
	localparam signed [31:0] SOFTMAX_LAT = 4;
	wire softmax_mode;
	assign softmax_mode = op_sel == 3'd3;
	wire [15:0] feed_end;
	wire [15:0] output_start;
	wire [15:0] output_end;
	wire [15:0] elemwise_end;
	assign feed_end = (({8'b00000000, tile_m} + {8'b00000000, tile_n}) + {8'b00000000, tile_k}) + 16'd2;
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	assign output_start = feed_end + sv2v_cast_16_signed(DRAIN_CYCLES);
	assign output_end = output_start + ({8'b00000000, tile_m} * {8'b00000000, tile_n});
	assign elemwise_end = output_end + sv2v_cast_16_signed(FUSED_DEPTH);
	wire [15:0] sm_feed_end;
	wire [15:0] sm_capture_start;
	wire [15:0] sm_capture_end;
	wire [15:0] sm_walk_start;
	wire [15:0] sm_walk_end;
	assign sm_feed_end = output_start + {8'b00000000, tile_m};
	assign sm_capture_start = output_start + sv2v_cast_16_signed(SOFTMAX_LAT);
	assign sm_capture_end = sm_capture_start + {8'b00000000, tile_m};
	assign sm_walk_start = sm_capture_end;
	assign sm_walk_end = sm_walk_start + ({8'b00000000, tile_m} * {8'b00000000, tile_n});
	wire [15:0] all_end;
	assign all_end = (softmax_mode ? sm_walk_end : elemwise_end);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			cycle_cnt <= 1'sb0;
			running <= 1'b0;
			done <= 1'b0;
		end
		else begin
			done <= 1'b0;
			if (start && !running) begin
				running <= 1'b1;
				cycle_cnt <= 1'sb0;
			end
			else if (running) begin
				cycle_cnt <= cycle_cnt + 16'd1;
				if (cycle_cnt >= all_end) begin
					running <= 1'b0;
					done <= 1'b1;
				end
			end
		end
	wire feed_active;
	assign feed_active = running && (cycle_cnt < feed_end);
	wire array_clear;
	assign array_clear = running && (cycle_cnt == 16'd0);
	wire signed [(ARRAY_DIM * 32) - 1:0] a_in_array;
	wire signed [(ARRAY_DIM * 32) - 1:0] b_in_array;
	wire feed_valid_a [0:ARRAY_DIM - 1];
	wire feed_valid_b [0:ARRAY_DIM - 1];
	wire [15:0] feed_idx_a [0:ARRAY_DIM - 1];
	wire [15:0] feed_idx_b [0:ARRAY_DIM - 1];
	genvar _gv_gr_1;
	genvar _gv_gc_1;
	function automatic signed [7:0] sv2v_cast_8_signed;
		input reg signed [7:0] inp;
		sv2v_cast_8_signed = inp;
	endfunction
	generate
		for (_gv_gr_1 = 0; _gv_gr_1 < ARRAY_DIM; _gv_gr_1 = _gv_gr_1 + 1) begin : gen_feed_a
			localparam gr = _gv_gr_1;
			assign feed_idx_a[gr] = (cycle_cnt - 16'd1) - sv2v_cast_16_signed(gr);
			assign feed_valid_a[gr] = ((feed_active && (cycle_cnt > sv2v_cast_16_signed(gr))) && (sv2v_cast_16_signed(gr) < {8'b00000000, tile_m})) && (feed_idx_a[gr] < {8'b00000000, tile_k});
			assign a_rd_row[((ARRAY_DIM - 1) - gr) * 8+:8] = sv2v_cast_8_signed(gr);
			assign a_rd_col[((ARRAY_DIM - 1) - gr) * 8+:8] = (feed_valid_a[gr] ? feed_idx_a[gr][7:0] : 8'd0);
			assign a_in_array[((ARRAY_DIM - 1) - gr) * 32+:32] = (feed_valid_a[gr] ? a_rd_data[((ARRAY_DIM - 1) - gr) * DATA_WIDTH+:DATA_WIDTH] : 32'sd0);
		end
		for (_gv_gc_1 = 0; _gv_gc_1 < ARRAY_DIM; _gv_gc_1 = _gv_gc_1 + 1) begin : gen_feed_b
			localparam gc = _gv_gc_1;
			assign feed_idx_b[gc] = (cycle_cnt - 16'd1) - sv2v_cast_16_signed(gc);
			assign feed_valid_b[gc] = ((feed_active && (cycle_cnt > sv2v_cast_16_signed(gc))) && (sv2v_cast_16_signed(gc) < {8'b00000000, tile_n})) && (feed_idx_b[gc] < {8'b00000000, tile_k});
			assign b_rd_row[((ARRAY_DIM - 1) - gc) * 8+:8] = (feed_valid_b[gc] ? feed_idx_b[gc][7:0] : 8'd0);
			assign b_rd_col[((ARRAY_DIM - 1) - gc) * 8+:8] = sv2v_cast_8_signed(gc);
			assign b_in_array[((ARRAY_DIM - 1) - gc) * 32+:32] = (feed_valid_b[gc] ? b_rd_data[((ARRAY_DIM - 1) - gc) * DATA_WIDTH+:DATA_WIDTH] : 32'sd0);
		end
	endgenerate
	wire signed [((ARRAY_DIM * ARRAY_DIM) * 32) - 1:0] c_out_array;
	systolic_array_64x64 #(
		.ROWS(ARRAY_DIM),
		.COLS(ARRAY_DIM),
		.DATA_WIDTH(32)
	) u_array(
		.clk(clk),
		.rst_n(rst_n),
		.en(feed_active),
		.clear_acc(array_clear),
		.a_in(a_in_array),
		.b_in(b_in_array),
		.c_out(c_out_array)
	);
	wire out_active;
	reg [7:0] out_row_cnt;
	reg [7:0] out_col_cnt;
	assign out_active = ((!softmax_mode && running) && (cycle_cnt >= output_start)) && (cycle_cnt < output_end);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_row_cnt <= 1'sb0;
			out_col_cnt <= 1'sb0;
		end
		else if (start && !running) begin
			out_row_cnt <= 1'sb0;
			out_col_cnt <= 1'sb0;
		end
		else if (out_active) begin
			if ((out_col_cnt + 8'd1) >= tile_n) begin
				out_col_cnt <= 1'sb0;
				out_row_cnt <= out_row_cnt + 8'd1;
			end
			else
				out_col_cnt <= out_col_cnt + 8'd1;
		end
	wire signed [31:0] mux_data;
	wire signed [31:0] aux_data;
	assign mux_data = c_out_array[((((ARRAY_DIM - 1) - out_row_cnt[5:0]) * ARRAY_DIM) + ((ARRAY_DIM - 1) - out_col_cnt[5:0])) * 32+:32];
	assign aux_rd_row = out_row_cnt;
	assign aux_rd_col = out_col_cnt;
	assign aux_data = aux_rd_data;
	wire signed [31:0] fused_out;
	wire fused_valid;
	fused_postproc_unit #(.DATA_WIDTH(32)) u_fused(
		.clk(clk),
		.rst_n(rst_n),
		.en(1'b1),
		.op_sel(op_sel),
		.data_in(mux_data),
		.in_valid(out_active),
		.aux_in(aux_data),
		.data_out(fused_out),
		.out_valid(fused_valid)
	);
	reg [7:0] coll_row_cnt;
	reg [7:0] coll_col_cnt;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			coll_row_cnt <= 1'sb0;
			coll_col_cnt <= 1'sb0;
		end
		else if (start && !running) begin
			coll_row_cnt <= 1'sb0;
			coll_col_cnt <= 1'sb0;
		end
		else if ((fused_valid && running) && !softmax_mode) begin
			if ((coll_col_cnt + 8'd1) >= tile_n) begin
				coll_col_cnt <= 1'sb0;
				coll_row_cnt <= coll_row_cnt + 8'd1;
			end
			else
				coll_col_cnt <= coll_col_cnt + 8'd1;
		end
	wire [15:0] sm_in_offset;
	wire [15:0] sm_capture_offset;
	assign sm_in_offset = cycle_cnt - output_start;
	assign sm_capture_offset = cycle_cnt - sm_capture_start;
	wire sm_in_valid;
	wire [7:0] sm_in_row;
	assign sm_in_valid = ((softmax_mode && running) && (cycle_cnt >= output_start)) && (cycle_cnt < sm_feed_end);
	assign sm_in_row = sm_in_offset[7:0];
	wire signed [(ARRAY_DIM * 32) - 1:0] sm_scores_in;
	wire signed [(ARRAY_DIM * 32) - 1:0] sm_probs_out;
	wire sm_out_valid;
	genvar _gv_gsi_1;
	generate
		for (_gv_gsi_1 = 0; _gv_gsi_1 < ARRAY_DIM; _gv_gsi_1 = _gv_gsi_1 + 1) begin : gen_sm_scores
			localparam gsi = _gv_gsi_1;
			assign sm_scores_in[((ARRAY_DIM - 1) - gsi) * 32+:32] = (sm_in_valid ? c_out_array[((((ARRAY_DIM - 1) - sm_in_row[5:0]) * ARRAY_DIM) + ((ARRAY_DIM - 1) - gsi)) * 32+:32] : 32'sd0);
		end
	endgenerate
	softmax_unit #(
		.DATA_WIDTH(32),
		.VEC_LEN(ARRAY_DIM)
	) u_softmax(
		.clk(clk),
		.rst_n(rst_n),
		.en(1'b1),
		.start(1'b0),
		.vec_len(tile_n),
		.scores_in(sm_scores_in),
		.in_valid(sm_in_valid),
		.probs_out(sm_probs_out),
		.out_valid(sm_out_valid)
	);
	wire sm_capture_active;
	wire [7:0] sm_capture_row;
	assign sm_capture_active = ((softmax_mode && sm_out_valid) && (cycle_cnt >= sm_capture_start)) && (cycle_cnt < sm_capture_end);
	assign sm_capture_row = sm_capture_offset[7:0];
	reg signed [31:0] sm_row_buf [0:ARRAY_DIM - 1][0:ARRAY_DIM - 1];
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin : sv2v_autoblock_1
			reg signed [31:0] r;
			for (r = 0; r < ARRAY_DIM; r = r + 1)
				begin : sv2v_autoblock_2
					reg signed [31:0] c;
					for (c = 0; c < ARRAY_DIM; c = c + 1)
						sm_row_buf[r][c] <= 1'sb0;
				end
		end
		else if (sm_capture_active) begin : sv2v_autoblock_3
			reg signed [31:0] c;
			for (c = 0; c < ARRAY_DIM; c = c + 1)
				sm_row_buf[sm_capture_row[5:0]][c] <= sm_probs_out[((ARRAY_DIM - 1) - c) * 32+:32];
		end
	wire sm_walk_active;
	reg [7:0] sm_walk_row_cnt;
	reg [7:0] sm_walk_col_cnt;
	assign sm_walk_active = ((softmax_mode && running) && (cycle_cnt >= sm_walk_start)) && (cycle_cnt < sm_walk_end);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			sm_walk_row_cnt <= 1'sb0;
			sm_walk_col_cnt <= 1'sb0;
		end
		else if (start && !running) begin
			sm_walk_row_cnt <= 1'sb0;
			sm_walk_col_cnt <= 1'sb0;
		end
		else if (sm_walk_active) begin
			if ((sm_walk_col_cnt + 8'd1) >= tile_n) begin
				sm_walk_col_cnt <= 1'sb0;
				sm_walk_row_cnt <= sm_walk_row_cnt + 8'd1;
			end
			else
				sm_walk_col_cnt <= sm_walk_col_cnt + 8'd1;
		end
	wire wr_en_em;
	wire wr_en_sm;
	wire [11:0] wr_idx_em;
	wire [11:0] wr_idx_sm;
	wire signed [31:0] wr_data_em;
	wire signed [31:0] wr_data_sm;
	assign wr_en_em = (!softmax_mode && fused_valid) && running;
	assign wr_idx_em = {coll_row_cnt[5:0], coll_col_cnt[5:0]};
	assign wr_data_em = fused_out;
	assign wr_en_sm = sm_walk_active;
	assign wr_idx_sm = {sm_walk_row_cnt[5:0], sm_walk_col_cnt[5:0]};
	assign wr_data_sm = sm_row_buf[sm_walk_row_cnt[5:0]][sm_walk_col_cnt[5:0]];
	assign out_wr_en = (softmax_mode ? wr_en_sm : wr_en_em);
	assign out_wr_idx = (softmax_mode ? wr_idx_sm : wr_idx_em);
	assign out_wr_data = (softmax_mode ? wr_data_sm : wr_data_em);
endmodule
module tile_dispatcher (
	clk,
	rst_n,
	macro_cmd,
	macro_valid,
	macro_ready,
	macro_done,
	lane_cmd,
	lane_cmd_valid,
	lane_cmd_ready,
	lane_done
);
	reg _sv2v_0;
	parameter signed [31:0] N_LANES = 16;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	parameter signed [31:0] TILE_DIM = accel_pkg_TILE_SIZE;
	input wire clk;
	input wire rst_n;
	input wire [106:0] macro_cmd;
	input wire macro_valid;
	output wire macro_ready;
	output reg macro_done;
	output reg [(N_LANES * 99) - 1:0] lane_cmd;
	output reg [0:N_LANES - 1] lane_cmd_valid;
	input wire [0:N_LANES - 1] lane_cmd_ready;
	input wire [0:N_LANES - 1] lane_done;
	localparam signed [31:0] LANE_ID_W = (N_LANES <= 1 ? 1 : $clog2(N_LANES));
	localparam signed [31:0] accel_pkg_N_SLOTS = 2;
	localparam signed [31:0] SLOT_ID_W = 1;
	reg [1:0] state;
	reg [106:0] cmd_reg;
	reg [7:0] m_idx;
	reg [7:0] n_idx;
	reg [15:0] tiles_issued;
	reg [15:0] tiles_completed;
	reg [15:0] total_tiles;
	reg in_flight [0:N_LANES - 1];
	reg completion_pulse [0:N_LANES - 1];
	reg [LANE_ID_W:0] num_completed;
	always @(*) begin
		if (_sv2v_0)
			;
		num_completed = 1'sb0;
		begin : sv2v_autoblock_1
			reg signed [31:0] l;
			for (l = 0; l < N_LANES; l = l + 1)
				begin
					completion_pulse[l] = in_flight[l] && lane_done[l];
					if (completion_pulse[l])
						num_completed = num_completed + 1;
				end
		end
	end
	wire [LANE_ID_W - 1:0] target_lane;
	wire [0:0] target_slot;
	assign target_lane = tiles_issued[LANE_ID_W - 1:0];
	assign target_slot = tiles_issued[LANE_ID_W+:SLOT_ID_W];
	wire can_dispatch;
	assign can_dispatch = ((state == 2'd1) && (tiles_issued < total_tiles)) && !in_flight[target_lane];
	wire [15:0] slot_offset;
	localparam signed [31:0] accel_pkg_SLOT_STRIDE = 64;
	function automatic [15:0] sv2v_cast_16;
		input reg [15:0] inp;
		sv2v_cast_16 = inp;
	endfunction
	function automatic signed [15:0] sv2v_cast_16_signed;
		input reg signed [15:0] inp;
		sv2v_cast_16_signed = inp;
	endfunction
	assign slot_offset = sv2v_cast_16(target_slot) * sv2v_cast_16_signed(accel_pkg_SLOT_STRIDE);
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_2
			reg signed [31:0] l;
			for (l = 0; l < N_LANES; l = l + 1)
				begin
					lane_cmd_valid[l] = 1'b0;
					lane_cmd[((N_LANES - 1) - l) * 99+:99] = 1'sb0;
				end
		end
		if (can_dispatch) begin
			lane_cmd_valid[target_lane] = 1'b1;
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 98-:3] = cmd_reg[106-:3];
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 95-:16] = cmd_reg[103-:16] + slot_offset;
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 79-:16] = cmd_reg[87-:16] + slot_offset;
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 63-:16] = cmd_reg[71-:16] + slot_offset;
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 47-:16] = cmd_reg[55-:16] + slot_offset;
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 31-:8] = cmd_reg[23-:8];
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 23-:8] = cmd_reg[15-:8];
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 15-:8] = cmd_reg[7-:8];
			lane_cmd[(((N_LANES - 1) - target_lane) * 99) + 7-:8] = 8'd0;
		end
	end
	assign macro_ready = state == 2'd0;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= 2'd0;
			cmd_reg <= 1'sb0;
			m_idx <= 1'sb0;
			n_idx <= 1'sb0;
			tiles_issued <= 1'sb0;
			tiles_completed <= 1'sb0;
			total_tiles <= 1'sb0;
			macro_done <= 1'b0;
			begin : sv2v_autoblock_3
				reg signed [31:0] l;
				for (l = 0; l < N_LANES; l = l + 1)
					in_flight[l] <= 1'b0;
			end
		end
		else begin
			macro_done <= 1'b0;
			tiles_completed <= tiles_completed + sv2v_cast_16(num_completed);
			begin : sv2v_autoblock_4
				reg signed [31:0] l;
				for (l = 0; l < N_LANES; l = l + 1)
					if (completion_pulse[l])
						in_flight[l] <= 1'b0;
			end
			case (state)
				2'd0:
					if (macro_valid) begin
						cmd_reg <= macro_cmd;
						m_idx <= 1'sb0;
						n_idx <= 1'sb0;
						tiles_issued <= 1'sb0;
						tiles_completed <= 1'sb0;
						total_tiles <= sv2v_cast_16(macro_cmd[39-:8]) * sv2v_cast_16(macro_cmd[31-:8]);
						state <= 2'd1;
					end
				2'd1: begin
					if (can_dispatch && lane_cmd_ready[target_lane]) begin
						in_flight[target_lane] <= 1'b1;
						tiles_issued <= tiles_issued + 16'd1;
						if ((n_idx + 8'd1) >= cmd_reg[31-:8]) begin
							n_idx <= 1'sb0;
							m_idx <= m_idx + 8'd1;
						end
						else
							n_idx <= n_idx + 8'd1;
					end
					if ((tiles_issued >= total_tiles) || ((can_dispatch && lane_cmd_ready[target_lane]) && ((tiles_issued + 16'd1) >= total_tiles)))
						state <= 2'd2;
				end
				2'd2:
					if ((tiles_completed + sv2v_cast_16(num_completed)) >= total_tiles)
						state <= 2'd3;
				2'd3: begin
					macro_done <= 1'b1;
					state <= 2'd0;
				end
				default: state <= 2'd0;
			endcase
		end
	initial _sv2v_0 = 0;
endmodule
module accel_controller (
	clk,
	rst_n,
	cmd,
	cmd_valid,
	cmd_ready,
	cmd_tile_m,
	cmd_tile_n,
	cmd_tile_k,
	fused_sel,
	sram_req,
	sram_we,
	sram_addr,
	sram_wdata,
	sram_rdata,
	sram_rvalid,
	buf_a_wr_en,
	buf_b_wr_en,
	buf_aux_wr_en,
	buf_wr_idx,
	buf_wr_data,
	out_rd_idx,
	out_rd_data,
	pipeline_start,
	pipeline_done,
	busy,
	done
);
	reg _sv2v_0;
	input wire clk;
	input wire rst_n;
	input wire [98:0] cmd;
	input wire cmd_valid;
	output reg cmd_ready;
	output wire [7:0] cmd_tile_m;
	output wire [7:0] cmd_tile_n;
	output wire [7:0] cmd_tile_k;
	output reg [2:0] fused_sel;
	output reg sram_req;
	output reg sram_we;
	output reg [15:0] sram_addr;
	output reg [31:0] sram_wdata;
	input wire [31:0] sram_rdata;
	input wire sram_rvalid;
	output reg buf_a_wr_en;
	output reg buf_b_wr_en;
	output reg buf_aux_wr_en;
	output reg [11:0] buf_wr_idx;
	output reg [31:0] buf_wr_data;
	output reg [11:0] out_rd_idx;
	input wire [31:0] out_rd_data;
	output reg pipeline_start;
	input wire pipeline_done;
	output reg busy;
	output reg done;
	reg [3:0] state;
	reg [98:0] cmd_reg;
	reg [11:0] load_cnt;
	reg [11:0] write_cnt;
	reg [7:0] load_row;
	reg [7:0] load_col;
	reg [7:0] wr_row;
	reg [7:0] wr_col;
	wire [11:0] tile_a_size;
	wire [11:0] tile_b_size;
	wire [11:0] tile_out_size;
	assign tile_a_size = {4'b0000, cmd_reg[31-:8]} * {4'b0000, cmd_reg[15-:8]};
	assign tile_b_size = {4'b0000, cmd_reg[15-:8]} * {4'b0000, cmd_reg[23-:8]};
	assign tile_out_size = {4'b0000, cmd_reg[31-:8]} * {4'b0000, cmd_reg[23-:8]};
	assign cmd_tile_m = cmd_reg[31-:8];
	assign cmd_tile_n = cmd_reg[23-:8];
	assign cmd_tile_k = cmd_reg[15-:8];
	always @(*) begin
		if (_sv2v_0)
			;
		case (cmd_reg[98-:3])
			3'd0: fused_sel = 3'd1;
			3'd1: fused_sel = 3'd2;
			3'd2: fused_sel = 3'd3;
			3'd3: fused_sel = 3'd0;
			default: fused_sel = 3'd0;
		endcase
	end
	always @(*) begin
		if (_sv2v_0)
			;
		cmd_ready = 1'b0;
		busy = 1'b0;
		done = 1'b0;
		sram_req = 1'b0;
		sram_we = 1'b0;
		sram_addr = 1'sb0;
		sram_wdata = 1'sb0;
		buf_a_wr_en = 1'b0;
		buf_b_wr_en = 1'b0;
		buf_aux_wr_en = 1'b0;
		buf_wr_idx = 1'sb0;
		buf_wr_data = 1'sb0;
		out_rd_idx = 1'sb0;
		pipeline_start = 1'b0;
		case (state)
			4'd0: cmd_ready = 1'b1;
			4'd1: begin
				busy = 1'b1;
				sram_req = 1'b1;
				sram_we = 1'b0;
				sram_addr = cmd_reg[95-:16] + {4'b0000, load_cnt};
				buf_a_wr_en = sram_rvalid;
				buf_wr_idx = {load_row[5:0], load_col[5:0]};
				buf_wr_data = sram_rdata;
			end
			4'd2: begin
				busy = 1'b1;
				sram_req = 1'b1;
				sram_we = 1'b0;
				sram_addr = cmd_reg[79-:16] + {4'b0000, load_cnt};
				buf_b_wr_en = sram_rvalid;
				buf_wr_idx = {load_row[5:0], load_col[5:0]};
				buf_wr_data = sram_rdata;
			end
			4'd3: begin
				busy = 1'b1;
				sram_req = 1'b1;
				sram_we = 1'b0;
				sram_addr = cmd_reg[63-:16] + {4'b0000, load_cnt};
				buf_aux_wr_en = sram_rvalid;
				buf_wr_idx = {load_row[5:0], load_col[5:0]};
				buf_wr_data = sram_rdata;
			end
			4'd4: begin
				busy = 1'b1;
				pipeline_start = 1'b1;
			end
			4'd5: busy = 1'b1;
			4'd6: begin
				busy = 1'b1;
				sram_req = 1'b1;
				sram_we = 1'b1;
				sram_addr = cmd_reg[47-:16] + {4'b0000, write_cnt};
				out_rd_idx = {wr_row[5:0], wr_col[5:0]};
				sram_wdata = out_rd_data;
			end
			4'd7: done = 1'b1;
			default:
				;
		endcase
	end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= 4'd0;
			cmd_reg <= 1'sb0;
			load_cnt <= 1'sb0;
			write_cnt <= 1'sb0;
			load_row <= 1'sb0;
			load_col <= 1'sb0;
			wr_row <= 1'sb0;
			wr_col <= 1'sb0;
		end
		else
			case (state)
				4'd0:
					if (cmd_valid) begin
						cmd_reg <= cmd;
						load_cnt <= 1'sb0;
						load_row <= 1'sb0;
						load_col <= 1'sb0;
						state <= 4'd1;
					end
				4'd1:
					if (sram_rvalid) begin
						if ((load_cnt + 12'd1) >= tile_a_size) begin
							load_cnt <= 1'sb0;
							load_row <= 1'sb0;
							load_col <= 1'sb0;
							state <= 4'd2;
						end
						else begin
							load_cnt <= load_cnt + 12'd1;
							if ((load_col + 8'd1) >= cmd_reg[15-:8]) begin
								load_col <= 1'sb0;
								load_row <= load_row + 8'd1;
							end
							else
								load_col <= load_col + 8'd1;
						end
					end
				4'd2:
					if (sram_rvalid) begin
						if ((load_cnt + 12'd1) >= tile_b_size) begin
							load_cnt <= 1'sb0;
							load_row <= 1'sb0;
							load_col <= 1'sb0;
							if (cmd_reg[98-:3] == 3'd1)
								state <= 4'd3;
							else
								state <= 4'd4;
						end
						else begin
							load_cnt <= load_cnt + 12'd1;
							if ((load_col + 8'd1) >= cmd_reg[23-:8]) begin
								load_col <= 1'sb0;
								load_row <= load_row + 8'd1;
							end
							else
								load_col <= load_col + 8'd1;
						end
					end
				4'd3:
					if (sram_rvalid) begin
						if ((load_cnt + 12'd1) >= tile_out_size) begin
							load_cnt <= 1'sb0;
							load_row <= 1'sb0;
							load_col <= 1'sb0;
							state <= 4'd4;
						end
						else begin
							load_cnt <= load_cnt + 12'd1;
							if ((load_col + 8'd1) >= cmd_reg[23-:8]) begin
								load_col <= 1'sb0;
								load_row <= load_row + 8'd1;
							end
							else
								load_col <= load_col + 8'd1;
						end
					end
				4'd4: state <= 4'd5;
				4'd5:
					if (pipeline_done) begin
						write_cnt <= 1'sb0;
						wr_row <= 1'sb0;
						wr_col <= 1'sb0;
						state <= 4'd6;
					end
				4'd6:
					if ((write_cnt + 12'd1) >= tile_out_size)
						state <= 4'd7;
					else begin
						write_cnt <= write_cnt + 12'd1;
						if ((wr_col + 8'd1) >= cmd_reg[23-:8]) begin
							wr_col <= 1'sb0;
							wr_row <= wr_row + 8'd1;
						end
						else
							wr_col <= wr_col + 8'd1;
					end
				4'd7: state <= 4'd0;
				default: state <= 4'd0;
			endcase
	initial _sv2v_0 = 0;
endmodule
module perf_counter_block (
	clk,
	rst_n,
	clear,
	array_active,
	array_stall,
	tile_complete,
	active_cycles,
	stall_cycles,
	total_cycles,
	tiles_completed
);
	input wire clk;
	input wire rst_n;
	input wire clear;
	input wire array_active;
	input wire array_stall;
	input wire tile_complete;
	output reg [31:0] active_cycles;
	output reg [31:0] stall_cycles;
	output reg [31:0] total_cycles;
	output reg [31:0] tiles_completed;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			active_cycles <= 1'sb0;
			stall_cycles <= 1'sb0;
			total_cycles <= 1'sb0;
			tiles_completed <= 1'sb0;
		end
		else if (clear) begin
			active_cycles <= 1'sb0;
			stall_cycles <= 1'sb0;
			total_cycles <= 1'sb0;
			tiles_completed <= 1'sb0;
		end
		else begin
			total_cycles <= total_cycles + 1;
			if (array_active)
				active_cycles <= active_cycles + 1;
			if (array_stall)
				stall_cycles <= stall_cycles + 1;
			if (tile_complete)
				tiles_completed <= tiles_completed + 1;
		end
endmodule
module accel_engine (
	clk,
	rst_n,
	cmd_in,
	cmd_valid,
	cmd_ready,
	sram_req,
	sram_we,
	sram_addr,
	sram_wdata,
	sram_rdata,
	sram_rvalid,
	busy,
	done,
	perf_active_cycles,
	perf_stall_cycles,
	perf_tiles_completed
);
	input wire clk;
	input wire rst_n;
	input wire [98:0] cmd_in;
	input wire cmd_valid;
	output wire cmd_ready;
	output wire sram_req;
	output wire sram_we;
	output wire [15:0] sram_addr;
	output wire [31:0] sram_wdata;
	input wire [31:0] sram_rdata;
	input wire sram_rvalid;
	output wire busy;
	output wire done;
	output wire [31:0] perf_active_cycles;
	output wire [31:0] perf_stall_cycles;
	output wire [31:0] perf_tiles_completed;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	localparam signed [31:0] TILE_DIM = accel_pkg_TILE_SIZE;
	wire [7:0] ctrl_tile_m;
	wire [7:0] ctrl_tile_n;
	wire [7:0] ctrl_tile_k;
	wire [2:0] fused_sel;
	wire buf_a_wr_en;
	wire buf_b_wr_en;
	wire buf_aux_wr_en;
	wire [11:0] buf_wr_idx;
	wire [31:0] buf_wr_data;
	wire [31:0] a_rd_row;
	wire [31:0] a_rd_col;
	wire signed [127:0] a_rd_data;
	wire [31:0] b_rd_row;
	wire [31:0] b_rd_col;
	wire signed [127:0] b_rd_data;
	wire [7:0] aux_rd_row;
	wire [7:0] aux_rd_col;
	wire signed [31:0] aux_rd_data;
	wire out_wr_en;
	wire [11:0] out_wr_idx;
	wire signed [31:0] out_wr_data;
	wire [11:0] out_rd_idx;
	wire signed [31:0] out_rd_data;
	wire signed [31:0] unused_buf_a_2d;
	wire signed [31:0] unused_buf_b_2d;
	wire signed [31:0] unused_buf_aux_2d;
	wire signed [31:0] unused_buf_a_lin;
	wire signed [31:0] unused_buf_b_lin;
	wire signed [31:0] unused_buf_aux_lin;
	wire signed [31:0] unused_out_2d;
	wire [7:0] unused_out_mp_row;
	wire [7:0] unused_out_mp_col;
	wire signed [31:0] unused_out_mp_data;
	assign unused_out_mp_row[0+:8] = 8'd0;
	assign unused_out_mp_col[0+:8] = 8'd0;
	wire pipeline_start;
	wire pipeline_done;
	wire pipeline_running;
	accel_controller u_ctrl(
		.clk(clk),
		.rst_n(rst_n),
		.cmd(cmd_in),
		.cmd_valid(cmd_valid),
		.cmd_ready(cmd_ready),
		.cmd_tile_m(ctrl_tile_m),
		.cmd_tile_n(ctrl_tile_n),
		.cmd_tile_k(ctrl_tile_k),
		.fused_sel(fused_sel),
		.sram_req(sram_req),
		.sram_we(sram_we),
		.sram_addr(sram_addr),
		.sram_wdata(sram_wdata),
		.sram_rdata(sram_rdata),
		.sram_rvalid(sram_rvalid),
		.buf_a_wr_en(buf_a_wr_en),
		.buf_b_wr_en(buf_b_wr_en),
		.buf_aux_wr_en(buf_aux_wr_en),
		.buf_wr_idx(buf_wr_idx),
		.buf_wr_data(buf_wr_data),
		.out_rd_idx(out_rd_idx),
		.out_rd_data(out_rd_data),
		.pipeline_start(pipeline_start),
		.pipeline_done(pipeline_done),
		.busy(busy),
		.done(done)
	);
	tile_buffer #(
		.DATA_WIDTH(32),
		.TILE_DIM(TILE_DIM),
		.NUM_RD_PORTS(TILE_DIM)
	) u_buf_a(
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(buf_a_wr_en),
		.wr_idx(buf_wr_idx),
		.wr_data($signed(buf_wr_data)),
		.rd_row(8'd0),
		.rd_col(8'd0),
		.rd_data(unused_buf_a_2d),
		.rd_lin_idx(12'd0),
		.rd_lin_data(unused_buf_a_lin),
		.mp_rd_row(a_rd_row),
		.mp_rd_col(a_rd_col),
		.mp_rd_data(a_rd_data)
	);
	tile_buffer #(
		.DATA_WIDTH(32),
		.TILE_DIM(TILE_DIM),
		.NUM_RD_PORTS(TILE_DIM)
	) u_buf_b(
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(buf_b_wr_en),
		.wr_idx(buf_wr_idx),
		.wr_data($signed(buf_wr_data)),
		.rd_row(8'd0),
		.rd_col(8'd0),
		.rd_data(unused_buf_b_2d),
		.rd_lin_idx(12'd0),
		.rd_lin_data(unused_buf_b_lin),
		.mp_rd_row(b_rd_row),
		.mp_rd_col(b_rd_col),
		.mp_rd_data(b_rd_data)
	);
	wire [7:0] aux_mp_row;
	wire [7:0] aux_mp_col;
	wire signed [31:0] aux_mp_data;
	assign aux_mp_row[0+:8] = aux_rd_row;
	assign aux_mp_col[0+:8] = aux_rd_col;
	assign aux_rd_data = aux_mp_data[0+:32];
	tile_buffer #(
		.DATA_WIDTH(32),
		.TILE_DIM(TILE_DIM),
		.NUM_RD_PORTS(1)
	) u_buf_aux(
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(buf_aux_wr_en),
		.wr_idx(buf_wr_idx),
		.wr_data($signed(buf_wr_data)),
		.rd_row(8'd0),
		.rd_col(8'd0),
		.rd_data(unused_buf_aux_2d),
		.rd_lin_idx(12'd0),
		.rd_lin_data(unused_buf_aux_lin),
		.mp_rd_row(aux_mp_row),
		.mp_rd_col(aux_mp_col),
		.mp_rd_data(aux_mp_data)
	);
	stream_pipeline #(
		.DATA_WIDTH(32),
		.ARRAY_DIM(TILE_DIM)
	) u_pipe(
		.clk(clk),
		.rst_n(rst_n),
		.start(pipeline_start),
		.done(pipeline_done),
		.tile_m(ctrl_tile_m),
		.tile_n(ctrl_tile_n),
		.tile_k(ctrl_tile_k),
		.op_sel(fused_sel),
		.a_rd_row(a_rd_row),
		.a_rd_col(a_rd_col),
		.a_rd_data(a_rd_data),
		.b_rd_row(b_rd_row),
		.b_rd_col(b_rd_col),
		.b_rd_data(b_rd_data),
		.aux_rd_row(aux_rd_row),
		.aux_rd_col(aux_rd_col),
		.aux_rd_data(aux_rd_data),
		.out_wr_en(out_wr_en),
		.out_wr_idx(out_wr_idx),
		.out_wr_data(out_wr_data),
		.running_o(pipeline_running)
	);
	tile_buffer #(
		.DATA_WIDTH(32),
		.TILE_DIM(TILE_DIM),
		.NUM_RD_PORTS(1)
	) u_buf_out(
		.clk(clk),
		.rst_n(rst_n),
		.wr_en(out_wr_en),
		.wr_idx(out_wr_idx),
		.wr_data(out_wr_data),
		.rd_row(8'd0),
		.rd_col(8'd0),
		.rd_data(unused_out_2d),
		.rd_lin_idx(out_rd_idx),
		.rd_lin_data(out_rd_data),
		.mp_rd_row(unused_out_mp_row),
		.mp_rd_col(unused_out_mp_col),
		.mp_rd_data(unused_out_mp_data)
	);
	perf_counter_block u_perf(
		.clk(clk),
		.rst_n(rst_n),
		.clear(!rst_n),
		.array_active(pipeline_start || pipeline_running),
		.array_stall(busy && !pipeline_running),
		.tile_complete(pipeline_done),
		.active_cycles(perf_active_cycles),
		.stall_cycles(perf_stall_cycles),
		.total_cycles(),
		.tiles_completed(perf_tiles_completed)
	);
endmodule
module accel_top (
	clk,
	rst_n,
	macro_cmd_in,
	macro_cmd_valid,
	macro_cmd_ready,
	dma_wr_valid,
	dma_wr_addr,
	dma_wr_data,
	dma_wr_ready,
	dma_rd_req,
	dma_rd_addr,
	dma_rd_data,
	dma_rd_valid,
	busy,
	done,
	irq,
	perf_active_cycles,
	perf_stall_cycles,
	perf_tiles_completed
);
	reg _sv2v_0;
	parameter signed [31:0] N_LANES = 16;
	localparam signed [31:0] accel_pkg_N_SLOTS = 2;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	localparam signed [31:0] accel_pkg_SLOT_STRIDE = 64;
	localparam signed [31:0] accel_pkg_LANE_LOCAL_W = $clog2(32'sd2 * 32'sd64);
	parameter signed [31:0] LANE_LOCAL_BITS = accel_pkg_LANE_LOCAL_W;
	parameter signed [31:0] LANE_BITS = (N_LANES <= 1 ? 1 : $clog2(N_LANES));
	parameter signed [31:0] DMA_ADDR_W = LANE_LOCAL_BITS + LANE_BITS;
	input wire clk;
	input wire rst_n;
	input wire [106:0] macro_cmd_in;
	input wire macro_cmd_valid;
	output wire macro_cmd_ready;
	input wire dma_wr_valid;
	input wire [DMA_ADDR_W - 1:0] dma_wr_addr;
	input wire [31:0] dma_wr_data;
	output wire dma_wr_ready;
	input wire dma_rd_req;
	input wire [DMA_ADDR_W - 1:0] dma_rd_addr;
	output wire [31:0] dma_rd_data;
	output wire dma_rd_valid;
	output wire busy;
	output wire done;
	output wire irq;
	output reg [31:0] perf_active_cycles;
	output reg [31:0] perf_stall_cycles;
	output reg [31:0] perf_tiles_completed;
	wire [(N_LANES * 99) - 1:0] lane_cmd;
	wire [0:N_LANES - 1] lane_cmd_valid;
	wire [0:N_LANES - 1] lane_cmd_ready;
	wire [0:N_LANES - 1] lane_done;
	wire lane_busy [0:N_LANES - 1];
	wire lane_sram_req [0:N_LANES - 1];
	wire lane_sram_we [0:N_LANES - 1];
	wire [15:0] lane_sram_addr [0:N_LANES - 1];
	wire [31:0] lane_sram_wdata [0:N_LANES - 1];
	wire [31:0] lane_sram_rdata [0:N_LANES - 1];
	wire lane_sram_rvalid [0:N_LANES - 1];
	wire [31:0] lane_perf_active [0:N_LANES - 1];
	wire [31:0] lane_perf_stall [0:N_LANES - 1];
	wire [31:0] lane_perf_tiles [0:N_LANES - 1];
	wire dispatcher_done;
	tile_dispatcher #(
		.N_LANES(N_LANES),
		.TILE_DIM(accel_pkg_TILE_SIZE)
	) u_dispatcher(
		.clk(clk),
		.rst_n(rst_n),
		.macro_cmd(macro_cmd_in),
		.macro_valid(macro_cmd_valid),
		.macro_ready(macro_cmd_ready),
		.macro_done(dispatcher_done),
		.lane_cmd(lane_cmd),
		.lane_cmd_valid(lane_cmd_valid),
		.lane_cmd_ready(lane_cmd_ready),
		.lane_done(lane_done)
	);
	wire dma_sram_req;
	wire dma_sram_we;
	wire [DMA_ADDR_W - 1:0] dma_sram_addr;
	wire [31:0] dma_sram_wdata;
	wire [31:0] dma_sram_rdata;
	wire dma_sram_rvalid;
	dma_engine #(
		.DATA_WIDTH(32),
		.ADDR_WIDTH(DMA_ADDR_W)
	) u_dma(
		.clk(clk),
		.rst_n(rst_n),
		.host_wr_valid(dma_wr_valid),
		.host_wr_addr(dma_wr_addr),
		.host_wr_data(dma_wr_data),
		.host_wr_ready(dma_wr_ready),
		.host_rd_req(dma_rd_req),
		.host_rd_addr(dma_rd_addr),
		.host_rd_data(dma_rd_data),
		.host_rd_valid(dma_rd_valid),
		.sram_req(dma_sram_req),
		.sram_we(dma_sram_we),
		.sram_addr(dma_sram_addr),
		.sram_wdata(dma_sram_wdata),
		.sram_rdata(dma_sram_rdata),
		.sram_rvalid(dma_sram_rvalid)
	);
	wire [LANE_BITS - 1:0] dma_lane_sel;
	wire [LANE_LOCAL_BITS - 1:0] dma_local_addr;
	assign dma_lane_sel = dma_sram_addr[LANE_LOCAL_BITS+:LANE_BITS];
	assign dma_local_addr = dma_sram_addr[LANE_LOCAL_BITS - 1:0];
	reg bank_dma_req [0:N_LANES - 1];
	reg bank_dma_we [0:N_LANES - 1];
	reg [15:0] bank_dma_addr [0:N_LANES - 1];
	reg [31:0] bank_dma_wdata [0:N_LANES - 1];
	wire [31:0] bank_dma_rdata [0:N_LANES - 1];
	wire bank_dma_rvalid [0:N_LANES - 1];
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] l;
			for (l = 0; l < N_LANES; l = l + 1)
				begin
					bank_dma_req[l] = 1'b0;
					bank_dma_we[l] = 1'b0;
					bank_dma_addr[l] = 1'sb0;
					bank_dma_wdata[l] = 1'sb0;
				end
		end
		bank_dma_req[dma_lane_sel] = dma_sram_req;
		bank_dma_we[dma_lane_sel] = dma_sram_we;
		bank_dma_addr[dma_lane_sel] = {{16 - LANE_LOCAL_BITS {1'b0}}, dma_local_addr};
		bank_dma_wdata[dma_lane_sel] = dma_sram_wdata;
	end
	reg [LANE_BITS - 1:0] dma_lane_sel_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			dma_lane_sel_q <= 1'sb0;
		else
			dma_lane_sel_q <= dma_lane_sel;
	assign dma_sram_rdata = bank_dma_rdata[dma_lane_sel_q];
	assign dma_sram_rvalid = bank_dma_rvalid[dma_lane_sel_q];
	genvar _gv_gl_1;
	generate
		for (_gv_gl_1 = 0; _gv_gl_1 < N_LANES; _gv_gl_1 = _gv_gl_1 + 1) begin : gen_lane
			localparam gl = _gv_gl_1;
			accel_engine u_engine(
				.clk(clk),
				.rst_n(rst_n),
				.cmd_in(lane_cmd[((N_LANES - 1) - gl) * 99+:99]),
				.cmd_valid(lane_cmd_valid[gl]),
				.cmd_ready(lane_cmd_ready[gl]),
				.sram_req(lane_sram_req[gl]),
				.sram_we(lane_sram_we[gl]),
				.sram_addr(lane_sram_addr[gl]),
				.sram_wdata(lane_sram_wdata[gl]),
				.sram_rdata(lane_sram_rdata[gl]),
				.sram_rvalid(lane_sram_rvalid[gl]),
				.busy(lane_busy[gl]),
				.done(lane_done[gl]),
				.perf_active_cycles(lane_perf_active[gl]),
				.perf_stall_cycles(lane_perf_stall[gl]),
				.perf_tiles_completed(lane_perf_tiles[gl])
			);
			scratchpad_ctrl u_bank(
				.clk(clk),
				.rst_n(rst_n),
				.a_req(lane_sram_req[gl] && !lane_sram_we[gl]),
				.a_addr(lane_sram_addr[gl]),
				.a_rdata(lane_sram_rdata[gl]),
				.a_rvalid(lane_sram_rvalid[gl]),
				.b_req(lane_sram_req[gl] && lane_sram_we[gl]),
				.b_we(lane_sram_we[gl]),
				.b_addr(lane_sram_addr[gl]),
				.b_wdata(lane_sram_wdata[gl]),
				.c_req(bank_dma_req[gl]),
				.c_we(bank_dma_we[gl]),
				.c_addr(bank_dma_addr[gl]),
				.c_wdata(bank_dma_wdata[gl]),
				.c_rdata(bank_dma_rdata[gl]),
				.c_rvalid(bank_dma_rvalid[gl])
			);
		end
	endgenerate
	reg any_busy;
	always @(*) begin
		if (_sv2v_0)
			;
		any_busy = 1'b0;
		begin : sv2v_autoblock_2
			reg signed [31:0] l;
			for (l = 0; l < N_LANES; l = l + 1)
				if (lane_busy[l])
					any_busy = 1'b1;
		end
	end
	assign busy = any_busy || !macro_cmd_ready;
	assign done = dispatcher_done;
	assign irq = dispatcher_done;
	always @(*) begin
		if (_sv2v_0)
			;
		perf_active_cycles = 1'sb0;
		perf_stall_cycles = 1'sb0;
		perf_tiles_completed = 1'sb0;
		begin : sv2v_autoblock_3
			reg signed [31:0] l;
			for (l = 0; l < N_LANES; l = l + 1)
				begin
					perf_active_cycles = perf_active_cycles + lane_perf_active[l];
					perf_stall_cycles = perf_stall_cycles + lane_perf_stall[l];
					perf_tiles_completed = perf_tiles_completed + lane_perf_tiles[l];
				end
		end
	end
	initial _sv2v_0 = 0;
endmodule
module compute_core (
	clk,
	rst_n,
	macro_cmd_in,
	macro_cmd_valid,
	macro_cmd_ready,
	dma_wr_valid,
	dma_wr_addr,
	dma_wr_data,
	dma_wr_ready,
	dma_rd_req,
	dma_rd_addr,
	dma_rd_data,
	dma_rd_valid,
	busy,
	done,
	irq,
	perf_active_cycles,
	perf_stall_cycles,
	perf_tiles_completed
);
	parameter signed [31:0] N_LANES = 16;
	localparam signed [31:0] accel_pkg_N_SLOTS = 2;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	localparam signed [31:0] accel_pkg_SLOT_STRIDE = 64;
	localparam signed [31:0] accel_pkg_LANE_LOCAL_W = $clog2(32'sd2 * 32'sd64);
	parameter signed [31:0] LANE_LOCAL_BITS = accel_pkg_LANE_LOCAL_W;
	parameter signed [31:0] LANE_BITS = (N_LANES <= 1 ? 1 : $clog2(N_LANES));
	parameter signed [31:0] DMA_ADDR_W = LANE_LOCAL_BITS + LANE_BITS;
	input wire clk;
	input wire rst_n;
	input wire [106:0] macro_cmd_in;
	input wire macro_cmd_valid;
	output wire macro_cmd_ready;
	input wire dma_wr_valid;
	input wire [DMA_ADDR_W - 1:0] dma_wr_addr;
	input wire [31:0] dma_wr_data;
	output wire dma_wr_ready;
	input wire dma_rd_req;
	input wire [DMA_ADDR_W - 1:0] dma_rd_addr;
	output wire [31:0] dma_rd_data;
	output wire dma_rd_valid;
	output wire busy;
	output wire done;
	output wire irq;
	output wire [31:0] perf_active_cycles;
	output wire [31:0] perf_stall_cycles;
	output wire [31:0] perf_tiles_completed;
	accel_top #(
		.N_LANES(N_LANES),
		.LANE_LOCAL_BITS(LANE_LOCAL_BITS),
		.LANE_BITS(LANE_BITS),
		.DMA_ADDR_W(DMA_ADDR_W)
	) u_accel_top(
		.clk(clk),
		.rst_n(rst_n),
		.macro_cmd_in(macro_cmd_in),
		.macro_cmd_valid(macro_cmd_valid),
		.macro_cmd_ready(macro_cmd_ready),
		.dma_wr_valid(dma_wr_valid),
		.dma_wr_addr(dma_wr_addr),
		.dma_wr_data(dma_wr_data),
		.dma_wr_ready(dma_wr_ready),
		.dma_rd_req(dma_rd_req),
		.dma_rd_addr(dma_rd_addr),
		.dma_rd_data(dma_rd_data),
		.dma_rd_valid(dma_rd_valid),
		.busy(busy),
		.done(done),
		.irq(irq),
		.perf_active_cycles(perf_active_cycles),
		.perf_stall_cycles(perf_stall_cycles),
		.perf_tiles_completed(perf_tiles_completed)
	);
endmodule
module chiplet_interface (
	clk,
	rst_n,
	ucie_cmd_valid,
	ucie_cmd_ready,
	ucie_cmd_data,
	ucie_wr_valid,
	ucie_wr_ready,
	ucie_wr_data,
	ucie_rd_req,
	ucie_rd_addr,
	ucie_rd_data,
	ucie_rd_valid,
	ucie_irq,
	ucie_busy,
	core_macro_cmd,
	core_macro_cmd_valid,
	core_macro_cmd_ready,
	core_dma_wr_valid,
	core_dma_wr_addr,
	core_dma_wr_data,
	core_dma_wr_ready,
	core_dma_rd_req,
	core_dma_rd_addr,
	core_dma_rd_data,
	core_dma_rd_valid,
	core_busy,
	core_irq
);
	localparam signed [31:0] accel_pkg_N_SLOTS = 2;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	localparam signed [31:0] accel_pkg_SLOT_STRIDE = 64;
	localparam signed [31:0] accel_pkg_LANE_LOCAL_W = $clog2(32'sd2 * 32'sd64);
	parameter signed [31:0] LANE_LOCAL_BITS = accel_pkg_LANE_LOCAL_W;
	parameter signed [31:0] LANE_BITS = 4;
	parameter signed [31:0] DMA_ADDR_W = LANE_LOCAL_BITS + LANE_BITS;
	parameter signed [31:0] CMD_BUS_W = 128;
	parameter signed [31:0] WR_BUS_W = DMA_ADDR_W + 32;
	input wire clk;
	input wire rst_n;
	input wire ucie_cmd_valid;
	output wire ucie_cmd_ready;
	input wire [CMD_BUS_W - 1:0] ucie_cmd_data;
	input wire ucie_wr_valid;
	output wire ucie_wr_ready;
	input wire [WR_BUS_W - 1:0] ucie_wr_data;
	input wire ucie_rd_req;
	input wire [DMA_ADDR_W - 1:0] ucie_rd_addr;
	output wire [31:0] ucie_rd_data;
	output wire ucie_rd_valid;
	output wire ucie_irq;
	output wire ucie_busy;
	output wire [106:0] core_macro_cmd;
	output wire core_macro_cmd_valid;
	input wire core_macro_cmd_ready;
	output wire core_dma_wr_valid;
	output wire [DMA_ADDR_W - 1:0] core_dma_wr_addr;
	output wire [31:0] core_dma_wr_data;
	input wire core_dma_wr_ready;
	output wire core_dma_rd_req;
	output wire [DMA_ADDR_W - 1:0] core_dma_rd_addr;
	input wire [31:0] core_dma_rd_data;
	input wire core_dma_rd_valid;
	input wire core_busy;
	input wire core_irq;
	assign core_macro_cmd = ucie_cmd_data[106:0];
	assign core_macro_cmd_valid = ucie_cmd_valid;
	assign ucie_cmd_ready = core_macro_cmd_ready;
	assign core_dma_wr_valid = ucie_wr_valid;
	assign core_dma_wr_addr = ucie_wr_data[32+:DMA_ADDR_W];
	assign core_dma_wr_data = ucie_wr_data[31:0];
	assign ucie_wr_ready = core_dma_wr_ready;
	assign core_dma_rd_req = ucie_rd_req;
	assign core_dma_rd_addr = ucie_rd_addr;
	assign ucie_rd_data = core_dma_rd_data;
	assign ucie_rd_valid = core_dma_rd_valid;
	assign ucie_busy = core_busy;
	assign ucie_irq = core_irq;
endmodule
module top_small (
	clk,
	rst_n,
	ucie_cmd_valid,
	ucie_cmd_ready,
	ucie_cmd_data,
	ucie_wr_valid,
	ucie_wr_ready,
	ucie_wr_data,
	ucie_rd_req,
	ucie_rd_addr,
	ucie_rd_data,
	ucie_rd_valid,
	ucie_irq,
	ucie_busy
);
	parameter signed [31:0] N_LANES = 1;
	localparam signed [31:0] accel_pkg_N_SLOTS = 2;
	localparam signed [31:0] accel_pkg_TILE_SIZE = 4;
	localparam signed [31:0] accel_pkg_SLOT_STRIDE = 64;
	localparam signed [31:0] accel_pkg_LANE_LOCAL_W = $clog2(32'sd2 * 32'sd64);
	parameter signed [31:0] LANE_LOCAL_BITS = accel_pkg_LANE_LOCAL_W;
	parameter signed [31:0] LANE_BITS = (N_LANES <= 1 ? 1 : $clog2(N_LANES));
	parameter signed [31:0] DMA_ADDR_W = LANE_LOCAL_BITS + LANE_BITS;
	parameter signed [31:0] CMD_BUS_W = 128;
	parameter signed [31:0] WR_BUS_W = DMA_ADDR_W + 32;
	input wire clk;
	input wire rst_n;
	input wire ucie_cmd_valid;
	output wire ucie_cmd_ready;
	input wire [CMD_BUS_W - 1:0] ucie_cmd_data;
	input wire ucie_wr_valid;
	output wire ucie_wr_ready;
	input wire [WR_BUS_W - 1:0] ucie_wr_data;
	input wire ucie_rd_req;
	input wire [DMA_ADDR_W - 1:0] ucie_rd_addr;
	output wire [31:0] ucie_rd_data;
	output wire ucie_rd_valid;
	output wire ucie_irq;
	output wire ucie_busy;
	wire [106:0] core_macro_cmd;
	wire core_macro_cmd_valid;
	wire core_macro_cmd_ready;
	wire core_dma_wr_valid;
	wire [DMA_ADDR_W - 1:0] core_dma_wr_addr;
	wire [31:0] core_dma_wr_data;
	wire core_dma_wr_ready;
	wire core_dma_rd_req;
	wire [DMA_ADDR_W - 1:0] core_dma_rd_addr;
	wire [31:0] core_dma_rd_data;
	wire core_dma_rd_valid;
	wire core_busy;
	wire core_done;
	wire core_irq;
	wire [31:0] perf_active;
	wire [31:0] perf_stall;
	wire [31:0] perf_tiles;
	chiplet_interface #(
		.LANE_LOCAL_BITS(LANE_LOCAL_BITS),
		.LANE_BITS(LANE_BITS),
		.DMA_ADDR_W(DMA_ADDR_W),
		.CMD_BUS_W(CMD_BUS_W),
		.WR_BUS_W(WR_BUS_W)
	) u_iface(
		.clk(clk),
		.rst_n(rst_n),
		.ucie_cmd_valid(ucie_cmd_valid),
		.ucie_cmd_ready(ucie_cmd_ready),
		.ucie_cmd_data(ucie_cmd_data),
		.ucie_wr_valid(ucie_wr_valid),
		.ucie_wr_ready(ucie_wr_ready),
		.ucie_wr_data(ucie_wr_data),
		.ucie_rd_req(ucie_rd_req),
		.ucie_rd_addr(ucie_rd_addr),
		.ucie_rd_data(ucie_rd_data),
		.ucie_rd_valid(ucie_rd_valid),
		.ucie_irq(ucie_irq),
		.ucie_busy(ucie_busy),
		.core_macro_cmd(core_macro_cmd),
		.core_macro_cmd_valid(core_macro_cmd_valid),
		.core_macro_cmd_ready(core_macro_cmd_ready),
		.core_dma_wr_valid(core_dma_wr_valid),
		.core_dma_wr_addr(core_dma_wr_addr),
		.core_dma_wr_data(core_dma_wr_data),
		.core_dma_wr_ready(core_dma_wr_ready),
		.core_dma_rd_req(core_dma_rd_req),
		.core_dma_rd_addr(core_dma_rd_addr),
		.core_dma_rd_data(core_dma_rd_data),
		.core_dma_rd_valid(core_dma_rd_valid),
		.core_busy(core_busy),
		.core_irq(core_irq)
	);
	compute_core #(
		.N_LANES(N_LANES),
		.LANE_LOCAL_BITS(LANE_LOCAL_BITS),
		.LANE_BITS(LANE_BITS),
		.DMA_ADDR_W(DMA_ADDR_W)
	) u_core(
		.clk(clk),
		.rst_n(rst_n),
		.macro_cmd_in(core_macro_cmd),
		.macro_cmd_valid(core_macro_cmd_valid),
		.macro_cmd_ready(core_macro_cmd_ready),
		.dma_wr_valid(core_dma_wr_valid),
		.dma_wr_addr(core_dma_wr_addr),
		.dma_wr_data(core_dma_wr_data),
		.dma_wr_ready(core_dma_wr_ready),
		.dma_rd_req(core_dma_rd_req),
		.dma_rd_addr(core_dma_rd_addr),
		.dma_rd_data(core_dma_rd_data),
		.dma_rd_valid(core_dma_rd_valid),
		.busy(core_busy),
		.done(core_done),
		.irq(core_irq),
		.perf_active_cycles(perf_active),
		.perf_stall_cycles(perf_stall),
		.perf_tiles_completed(perf_tiles)
	);
endmodule
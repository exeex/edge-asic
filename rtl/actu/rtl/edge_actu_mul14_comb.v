`timescale 1ns/1ps

// Preserved physical leaf for one native-BF22 significand multiply.  Split one
// operand into two 7-bit halves, register both 14x7 partial products, and leave
// only their shifted sum on the following stage.  A new operand is accepted
// every cycle; the owning finalizer captures product_o one cycle later.
(* keep_hierarchy = "yes" *)
module edge_actu_mul14_comb #(
  parameter RESET_DATA = 1
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire [13:0] lhs_sig_i,
  input  wire [13:0] rhs_sig_i,
  output wire [27:0] product_o
);

reg [20:0] product_lo_q;
reg [20:0] product_hi_q;

assign product_o = {7'b0, product_lo_q} + {product_hi_q, 7'b0};

generate
if (RESET_DATA) begin : g_reset_data
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    product_lo_q <= 21'b0;
    product_hi_q <= 21'b0;
  end else begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end
end else begin : g_unreset_data
  // The owning pipeline valid state cancels in-flight products on reset.
  always @(posedge clk) begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end
endgenerate

endmodule

// Preserved fixed-point Newton leaf for Q12-by-Q13 style products.  The
// constant round and discarded low bits stay inside the multiplier boundary.
// Two registered 14x7 partial products feed the shifted sum and original
// round/slice logic in the following stage.
(* keep_hierarchy = "yes" *)
module edge_actu_mul14_round9_q16 #(
  parameter RESET_DATA = 1
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire [13:0] lhs_sig_i,
  input  wire [13:0] rhs_sig_i,
  output wire [17:0] result_q16_o
);

reg [20:0] product_lo_q;
reg [20:0] product_hi_q;
wire [27:0] product;
wire [27:0] rounded_product;

assign product = {7'b0, product_lo_q} + {product_hi_q, 7'b0};
assign rounded_product = product + 28'h0000100;
assign result_q16_o = rounded_product[26:9];

generate
if (RESET_DATA) begin : g_reset_data
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    product_lo_q <= 21'b0;
    product_hi_q <= 21'b0;
  end else begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end

end else begin : g_unreset_data
  always @(posedge clk) begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end
endgenerate

endmodule

// Preserved fixed-point Newton result leaf.  This is the same arithmetic as
// `(lhs * rhs + 0x200) >> 10`; only the synthesis boundary moves inward.
(* keep_hierarchy = "yes" *)
module edge_actu_mul14_round10_q16 #(
  parameter RESET_DATA = 1
) (
  input  wire        clk,
  input  wire        cpurst_b,
  input  wire [13:0] lhs_sig_i,
  input  wire [13:0] rhs_sig_i,
  output wire [17:0] result_q16_o
);

reg [20:0] product_lo_q;
reg [20:0] product_hi_q;
wire [27:0] product;
wire [27:0] rounded_product;

assign product = {7'b0, product_lo_q} + {product_hi_q, 7'b0};
assign rounded_product = product + 28'h0000200;
assign result_q16_o = rounded_product[27:10];

generate
if (RESET_DATA) begin : g_reset_data
always @(posedge clk or negedge cpurst_b) begin
  if (!cpurst_b) begin
    product_lo_q <= 21'b0;
    product_hi_q <= 21'b0;
  end else begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end

end else begin : g_unreset_data
  always @(posedge clk) begin
    product_lo_q <= lhs_sig_i * rhs_sig_i[6:0];
    product_hi_q <= lhs_sig_i * rhs_sig_i[13:7];
  end
end
endgenerate

endmodule

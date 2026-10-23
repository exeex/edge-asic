// One local WLD stop: select north/west, take this element, relay the remainder.
// A packed packet contains 1/2/4 adjacent source rows from a single column.
module edge_wld_relay_cell #(
  parameter ROW=0, COL=0, INDEX_BITS=3
)(
  input wire clk, input wire rst_b, input wire advance_i,
  input wire transpose_i, input wire [1:0] width_code_i,
  input wire north_valid_i, input wire [15:0] north_data_i,
  input wire [INDEX_BITS-1:0] north_base_i,
  input wire west_valid_i, input wire [15:0] west_data_i,
  input wire [INDEX_BITS-1:0] west_base_i,
  output reg relay_valid_o, output reg [15:0] relay_data_o,
  output reg [INDEX_BITS-1:0] relay_base_o,
  output wire take_valid_o, output reg [15:0] take_data_o
);
wire incoming_valid=transpose_i ? west_valid_i : north_valid_i;
wire [15:0] incoming_data=transpose_i ? west_data_i : north_data_i;
wire [INDEX_BITS-1:0] incoming_base=transpose_i ? west_base_i : north_base_i;
wire [INDEX_BITS:0] position=transpose_i ? (INDEX_BITS+1)'(COL) : (INDEX_BITS+1)'(ROW);
wire [INDEX_BITS:0] group_size=(INDEX_BITS+1)'(1) << width_code_i;
wire [INDEX_BITS:0] limit={1'b0,incoming_base} + group_size;
wire [INDEX_BITS:0] offset=position-{1'b0,incoming_base};
assign take_valid_o=rst_b && advance_i && incoming_valid
                    && offset<group_size;
always @* begin
  case (width_code_i)
    0: take_data_o=incoming_data;
    1: take_data_o={8'b0,incoming_data[offset[0]*8 +: 8]};
    default: take_data_o={12'b0,incoming_data[offset[1:0]*4 +: 4]};
  endcase
end
// Only valid requires reset. This stage never waits for a downstream credit:
// the whole inactive-bank route is reserved before accepting a WLD command.
always @(posedge clk or negedge rst_b) begin
  if (!rst_b) relay_valid_o<=0;
  else if (advance_i) relay_valid_o<=incoming_valid && position+1'b1<limit;
end
always @(posedge clk) begin
  if (advance_i && incoming_valid && position+1'b1<limit) begin
    relay_data_o<=incoming_data; relay_base_o<=incoming_base;
  end
end
endmodule

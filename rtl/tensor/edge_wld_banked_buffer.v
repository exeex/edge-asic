// Packed tile storage with static write destinations and dot-local read banks.
// wtype: 0=BF16, 1=I8, 2=FP8, 3=FP4. Numerical decoding is downstream.
module edge_wld_banked_buffer #(
  parameter DOTS=8,
  parameter INDEX_BITS=$clog2(DOTS)
)(
  input wire clk, input wire rst_b,
  input wire start_i, output wire start_ready_o,
  input wire [1:0] wtype_i, input wire transpose_i,
  input wire load_valid_i, output wire load_ready_o,
  input wire [DOTS*16-1:0] load_data_i,
  output wire drain_valid_o, input wire drain_ready_i,
  output wire [DOTS*16-1:0] drain_data_o,
  output wire [1:0] wtype_o,
  output wire drain_last_o, output wire load_last_o, output wire busy_o, output reg done_o
);
  reg active_q, transpose_q;
  reg [1:0] wtype_q;
  reg [INDEX_BITS:0] written_q;
  reg [INDEX_BITS-1:0] element_q, head_q;
  reg [1:0] subword_q;
  wire [1:0] width_code = wtype_q==0 ? 2'd0 : wtype_q==3 ? 2'd2 : 2'd1;
  wire [INDEX_BITS:0] beat_limit = (INDEX_BITS+1)'(DOTS) >> width_code;
  wire last_subword = {1'b0,subword_q} == ((3'd1 << width_code)-1'b1);
  wire start_fire = start_i && start_ready_o;
  wire push = load_valid_i && load_ready_o;
  wire pop = drain_valid_o && drain_ready_i;

  assign start_ready_o = !active_q;
  assign busy_o = active_q;
  assign wtype_o = wtype_q;
  // A transaction owns a complete worst-case BF16 tile, independent of drain.
  assign load_ready_o = active_q && written_q < beat_limit;
  assign load_last_o = load_ready_o && written_q == beat_limit-1'b1;
  // Normal rows must all arrive before the first across-dot vector. Transpose
  // writes one packed halfword per dot per beat, and may stream immediately.
  assign drain_valid_o = active_q && (transpose_q ? written_q > {1'b0,head_q}
                                                  : written_q == beat_limit);
  assign drain_last_o = drain_valid_o && element_q == INDEX_BITS'(DOTS-1);

  genvar dot, page, slot;
  generate for (dot=0;dot<DOTS;dot=dot+1) begin : GEN_DOT
    // Pages contain eight fixed 16-bit words, irrespective of total tile size.
    wire [15:0] page_data [0:DOTS/8-1];
    wire [15:0] packed_word = page_data[head_q >> 3];
    for (page=0;page<DOTS/8;page=page+1) begin : GEN_PAGE
      reg [15:0] words_q [0:7];
      assign page_data[page] = words_q[head_q[2:0]];
      for (slot=0;slot<8;slot=slot+1) begin : GEN_SLOT
        localparam WORD=page*8+slot;
        reg write_enable;
        reg [15:0] write_data;
        always @* begin
          write_enable=0;
          write_data=0;
          if (transpose_q) begin
            write_enable = written_q == (INDEX_BITS+1)'(WORD);
            case (width_code)
              0: write_data=load_data_i[dot*16+:16];
              1: write_data={load_data_i[(DOTS+dot)*8+:8],
                             load_data_i[dot*8+:8]};
              2: write_data={load_data_i[(3*DOTS+dot)*4+:4],
                             load_data_i[(2*DOTS+dot)*4+:4],
                             load_data_i[(DOTS+dot)*4+:4],
                             load_data_i[dot*4+:4]};
              default: begin end
            endcase
          end else begin
            case (width_code)
              0: begin
                write_enable = written_q == (INDEX_BITS+1)'(dot);
                write_data=load_data_i[WORD*16+:16];
              end
              1: if (WORD < DOTS/2) begin
                write_enable = written_q == (INDEX_BITS+1)'(dot/2);
                write_data=load_data_i[((dot%2)*(DOTS/2)+WORD)*16+:16];
              end
              2: if (WORD < DOTS/4) begin
                write_enable = written_q == (INDEX_BITS+1)'(dot/4);
                write_data=load_data_i[((dot%4)*(DOTS/4)+WORD)*16+:16];
              end
              default: begin end
            endcase
          end
        end
        always @(posedge clk)
          if (push && write_enable) words_q[slot] <= write_data;
      end
    end
    // Buffer reads always advance one packed halfword. This small serializer
    // alone selects its 16/8/4-bit element, preserving bits without conversion.
    assign drain_data_o[dot*16+:16] = width_code==0 ? packed_word :
      width_code==1 ? {8'b0,packed_word[subword_q[0]*8+:8]} :
                      {12'b0,packed_word[subword_q*4+:4]};
  end endgenerate

  always @(posedge clk or negedge rst_b) begin
    if (!rst_b) begin
      active_q<=0; transpose_q<=0; wtype_q<=0; written_q<=0;
      element_q<=0; head_q<=0; subword_q<=0; done_o<=0;
    end else begin
      done_o<=0;
      if (start_fire) begin
        active_q<=1; transpose_q<=transpose_i; wtype_q<=wtype_i;
        written_q<=0; element_q<=0; head_q<=0; subword_q<=0;
      end else begin
        if (push) written_q<=written_q+1'b1;
        if (pop) begin
          element_q<=element_q+1'b1;
          if (last_subword) begin head_q<=head_q+1'b1; subword_q<=0; end
          else subword_q<=subword_q+1'b1;
          if (drain_last_o) begin active_q<=0; done_o<=1; end
        end
      end
    end
  end
`ifndef SYNTHESIS
  initial if (DOTS!=8 && DOTS!=16 && DOTS!=32)
    $fatal(1,"WLD banked buffer supports dot8/dot16/dot32");
  always @(posedge clk)
    if (rst_b && pop && drain_last_o && written_q!=beat_limit)
      $fatal(1,"WLD banked buffer completed before all input beats");
`endif
endmodule

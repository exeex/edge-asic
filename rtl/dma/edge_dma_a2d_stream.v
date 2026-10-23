// Ordered AXI reader with optional contiguous-command burst gathering.
module edge_dma_a2d_stream #(
  parameter AXI_ADDR_WIDTH = 40,
  parameter DTCM_ADDR_WIDTH = 14,
  parameter FIFO_DEPTH = 16,
  parameter BURST_MAX_BEATS = 1,
  parameter FIFO_PTR_WIDTH = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH)
) (
  input  wire                       clk,
  input  wire                       reset_b,
  input  wire                       cmd_valid,
  output wire                       cmd_ready,
  input  wire [AXI_ADDR_WIDTH-1:0]  cmd_axi_addr,
  input  wire [DTCM_ADDR_WIDTH-1:0] cmd_dtcm_addr,
  output wire [AXI_ADDR_WIDTH-1:0]  axi_araddr,
  output wire [7:0]                 axi_arlen,
  output wire                       axi_arvalid,
  input  wire                       axi_arready,
  input  wire [127:0]               axi_rdata,
  input  wire                       axi_rvalid,
  output wire                       axi_rready,
  output wire                       dtcm_req,
  output wire [DTCM_ADDR_WIDTH-1:0] dtcm_addr,
  output wire [127:0]               dtcm_wdata,
  output wire [15:0]                dtcm_wstrb,
  input  wire                       dtcm_ready,
  output wire                       beat_done,
  output wire                       busy,
  output wire [2:0]                 lease_channel,
  output wire [8:0]                 lease_cycles,
  output wire [3:0]                 lease_delay,
  output wire                       lease_valid,
  output wire [FIFO_PTR_WIDTH:0]    outstanding_count,
  output wire [FIFO_PTR_WIDTH:0]    buffered_count
);

  reg [DTCM_ADDR_WIDTH-1:0] descriptor_q [0:FIFO_DEPTH-1];
  reg [FIFO_PTR_WIDTH-1:0] descriptor_write_ptr_q;
  reg [FIFO_PTR_WIDTH-1:0] descriptor_read_ptr_q;
  reg [FIFO_PTR_WIDTH:0] descriptor_count_q;
  wire descriptor_full = descriptor_count_q == FIFO_DEPTH[FIFO_PTR_WIDTH:0];
  wire descriptor_empty = descriptor_count_q == 0;
  wire [DTCM_ADDR_WIDTH-1:0] response_dtcm_addr =
    descriptor_q[descriptor_read_ptr_q];

  wire fifo_push_ready;
  wire fifo_pop_valid;
  wire [127:0] fifo_pop_data;
  wire [15:0] fifo_pop_wstrb;
  wire [15:0] fifo_pop_meta;
  wire [FIFO_PTR_WIDTH:0] fifo_occupancy;
  wire reserved_full =
    (descriptor_count_q + fifo_occupancy) >= FIFO_DEPTH[FIFO_PTR_WIDTH:0];
  wire ar_fire;
  wire r_fire;
  wire dtcm_fire;
  reg [2:0] lease_phase_q;

  wire cmd_fire = cmd_valid && cmd_ready;
  wire [FIFO_PTR_WIDTH:0] pending_count;
  wire [DTCM_ADDR_WIDTH-1:0] lease_addr;
  generate if (BURST_MAX_BEATS == 1) begin: SINGLE_BEAT
    assign cmd_ready = !reserved_full && !descriptor_full && axi_arready;
    assign axi_arvalid = cmd_valid && !reserved_full && !descriptor_full;
    assign axi_araddr = cmd_axi_addr;
    assign axi_arlen = 8'd0;
    assign pending_count = 0;
    assign lease_addr = cmd_dtcm_addr;
  end else begin: BURST
    reg [AXI_ADDR_WIDTH-1:0] base_q, next_axi_q;
    reg [DTCM_ADDR_WIDTH-1:0] first_dtcm_q, next_dtcm_q;
    reg [FIFO_PTR_WIDTH:0] count_q;
    reg sealed_q;
    wire contiguous = cmd_axi_addr == next_axi_q &&
                      cmd_dtcm_addr == next_dtcm_q &&
                      cmd_axi_addr[AXI_ADDR_WIDTH-1:12] == base_q[AXI_ADDR_WIDTH-1:12];
    assign pending_count = count_q;
    assign cmd_ready = !sealed_q && !reserved_full && !descriptor_full &&
                       (count_q == 0 || contiguous);
    assign axi_arvalid = sealed_q;
    assign axi_araddr = base_q;
    assign axi_arlen = 8'(count_q - 1'b1);
    assign lease_addr = first_dtcm_q;
    always @(posedge clk or negedge reset_b) begin
      if (!reset_b) begin
        base_q <= 0; next_axi_q <= 0; first_dtcm_q <= 0;
        next_dtcm_q <= 0; count_q <= 0; sealed_q <= 0;
      end else begin
        // A gap flushes a short tail. Credit pressure from older responses
        // does not seal a small burst: their DTCM drain will free credits.
        if (count_q != 0 && (!cmd_valid || !contiguous ||
            (reserved_full && descriptor_count_q == count_q && fifo_occupancy == 0)))
          sealed_q <= 1;
        if (cmd_fire) begin
          if (count_q == 0) begin
            base_q <= cmd_axi_addr;
            first_dtcm_q <= cmd_dtcm_addr;
          end
          next_axi_q <= cmd_axi_addr + AXI_ADDR_WIDTH'(16);
          next_dtcm_q <= cmd_dtcm_addr + DTCM_ADDR_WIDTH'(2);
          count_q <= count_q + 1'b1;
          if (count_q + 1'b1 == BURST_MAX_BEATS || cmd_axi_addr[11:0] == 12'hff0)
            sealed_q <= 1;
        end
        if (ar_fire) begin count_q <= 0; sealed_q <= 0; end
      end
    end
  end endgenerate
  assign ar_fire = axi_arvalid && axi_arready;
  assign axi_rready = (descriptor_count_q > pending_count) && fifo_push_ready;
  assign r_fire = axi_rvalid && axi_rready;
  assign dtcm_req = fifo_pop_valid;
  assign dtcm_addr = fifo_pop_meta[DTCM_ADDR_WIDTH-1:0];
  assign dtcm_wdata = fifo_pop_data;
  assign dtcm_wstrb = fifo_pop_wstrb;
  assign dtcm_fire = fifo_pop_valid && dtcm_ready;
  assign beat_done = dtcm_fire;
  assign busy = !descriptor_empty || (fifo_occupancy != 0);
  assign outstanding_count = descriptor_count_q - pending_count;
  assign buffered_count = fifo_occupancy;
  assign lease_valid = ar_fire;
  assign lease_channel = lease_addr[3:1] -
                         (lease_phase_q + 3'd3);
  assign lease_cycles = {1'b0, axi_arlen} + 9'd1;
  assign lease_delay = 4'd3;

  edge_dma_read_fifo #(
    .DEPTH(FIFO_DEPTH)
  ) response_fifo (
    .clk(clk),
    .reset_b(reset_b),
    .push_valid(r_fire),
    .push_ready(fifo_push_ready),
    .push_data(axi_rdata),
    .push_wstrb(16'hffff),
    .push_meta({{(16-DTCM_ADDR_WIDTH){1'b0}}, response_dtcm_addr}),
    .pop_valid(fifo_pop_valid),
    .pop_ready(dtcm_ready),
    .pop_data(fifo_pop_data),
    .pop_wstrb(fifo_pop_wstrb),
    .pop_meta(fifo_pop_meta),
    .occupancy(fifo_occupancy)
  );

  always @(posedge clk or negedge reset_b) begin
    if (!reset_b) begin
      descriptor_write_ptr_q <= {FIFO_PTR_WIDTH{1'b0}};
      descriptor_read_ptr_q <= {FIFO_PTR_WIDTH{1'b0}};
      descriptor_count_q <= {(FIFO_PTR_WIDTH+1){1'b0}};
      lease_phase_q <= 3'b0;
    end else begin
      lease_phase_q <= lease_phase_q + 1'b1;
      if (cmd_fire) begin
        descriptor_q[descriptor_write_ptr_q] <= cmd_dtcm_addr;
        descriptor_write_ptr_q <= descriptor_write_ptr_q + 1'b1;
      end
      if (r_fire)
        descriptor_read_ptr_q <= descriptor_read_ptr_q + 1'b1;
      case ({cmd_fire, r_fire})
        2'b10: descriptor_count_q <= descriptor_count_q + 1'b1;
        2'b01: descriptor_count_q <= descriptor_count_q - 1'b1;
        default: descriptor_count_q <= descriptor_count_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (BURST_MAX_BEATS < 1 || BURST_MAX_BEATS > FIFO_DEPTH || BURST_MAX_BEATS > 256 ||
        FIFO_DEPTH != (1 << FIFO_PTR_WIDTH)) $fatal(1, "invalid DMA burst/FIFO parameters");
  end
  always @(posedge clk) if (reset_b) begin
    if (({1'b0,descriptor_count_q} + {1'b0,fifo_occupancy}) > FIFO_DEPTH)
      $fatal(1, "DMA response credits exceeded");
    if (cmd_fire && cmd_axi_addr[3:0] != 0) $fatal(1, "unaligned DMA stream command");
  end
`endif
endmodule

// Memory-resident layer program for the fixed-latency word memory interface.
// AI assistance: Codex.
`timescale 1ns/1ps
module conv_program #(
    parameter ARRAY_SIZE = 10, BIT_WIDTH = 8, ACC_WIDTH = 32,
    parameter INPUT_ADDR_WIDTH = 8, OUTPUT_ADDR_WIDTH = 8, KERNEL_ADDR_WIDTH = 8,
    parameter CFG_WIDTH = 32, MEM_ADDR_WIDTH = 32,
    parameter MEM_DATA_WIDTH = (ACC_WIDTH > 32 ? ACC_WIDTH : 32)
) (
    input clk, nrst, start,
    input [MEM_ADDR_WIDTH-1:0] program_base,
    output chain_busy, chain_done,
    output mem_re, mem_we,
    output [MEM_ADDR_WIDTH-1:0] mem_raddr, mem_waddr,
    input [MEM_DATA_WIDTH-1:0] mem_rdata,
    output [MEM_DATA_WIDTH-1:0] mem_wdata
);
  localparam [1:0] IDLE = 0, FETCH = 1, ISSUE = 2, RUN = 3;
  localparam [4:0] DESCRIPTOR_WORDS = 27;

  reg [1:0] state;
  reg [MEM_ADDR_WIDTH-1:0] pc;
  reg [4:0] fetch_index;
  reg [31:0] descriptor [0:DESCRIPTOR_WORDS-1];

  wire descriptor_ready;
  wire descriptor_valid = state == ISSUE;
  wire busy, done, layer_chain_done;
  wire layer_mem_re;
  wire [MEM_ADDR_WIDTH-1:0] layer_mem_raddr;
  wire fetching = nrst && state == FETCH && fetch_index < DESCRIPTOR_WORDS;

  assign chain_busy = state != IDLE;
  assign chain_done = state == RUN && layer_chain_done;
  assign mem_re = fetching || layer_mem_re;
  assign mem_raddr = fetching ? pc + MEM_ADDR_WIDTH'(fetch_index) : layer_mem_raddr;

  always @(posedge clk) begin
    if (!nrst) begin
      state <= IDLE;
      pc <= 0;
      fetch_index <= 0;
    end else begin
      case (state)
        IDLE: if (start) begin
          pc <= program_base;
          fetch_index <= 0;
          state <= FETCH;
        end
        FETCH: begin
          // Issue one read per cycle, capturing the preceding read's data.
          // Issue only after the final synchronous response reaches the buffer.
          if (fetch_index != 0)
            descriptor[fetch_index - 5'd1] <= mem_rdata[31:0];
          if (fetching)
            fetch_index <= fetch_index + 5'd1;
          else
            state <= ISSUE;
        end
        ISSUE: if (descriptor_ready)
          state <= RUN;
        RUN: if (done) begin
          if (layer_chain_done) begin
            state <= IDLE;
          end else begin
            pc <= pc + MEM_ADDR_WIDTH'(DESCRIPTOR_WORDS);
            fetch_index <= 0;
            state <= FETCH;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end

  // Word 22 is the reference output count for fixture checkers.
  conv_chain #(
    .ARRAY_SIZE(ARRAY_SIZE), .BIT_WIDTH(BIT_WIDTH), .ACC_WIDTH(ACC_WIDTH),
    .INPUT_ADDR_WIDTH(INPUT_ADDR_WIDTH), .OUTPUT_ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
    .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH), .CFG_WIDTH(CFG_WIDTH),
    .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH), .MEM_DATA_WIDTH(MEM_DATA_WIDTH)
  ) u_chain (
    .clk(clk), .nrst(nrst), .descriptor_valid(descriptor_valid),
    .descriptor_ready(descriptor_ready), .descriptor_last(descriptor[21][0]),
    .busy(busy), .done(done), .chain_busy(), .chain_done(layer_chain_done),
    .cfg_N(CFG_WIDTH'(descriptor[0])), .cfg_C(CFG_WIDTH'(descriptor[1])),
    .cfg_H(CFG_WIDTH'(descriptor[2])), .cfg_W(CFG_WIDTH'(descriptor[3])),
    .cfg_K(CFG_WIDTH'(descriptor[4])), .cfg_R(CFG_WIDTH'(descriptor[5])),
    .cfg_S(CFG_WIDTH'(descriptor[6])), .cfg_P(CFG_WIDTH'(descriptor[7])),
    .cfg_Q(CFG_WIDTH'(descriptor[8])),
    .cfg_pad_i(CFG_WIDTH'(descriptor[9])), .cfg_pad_j(CFG_WIDTH'(descriptor[10])),
    .cfg_stride_i(CFG_WIDTH'(descriptor[11])), .cfg_stride_j(CFG_WIDTH'(descriptor[12])),
    .cfg_dilation_i(CFG_WIDTH'(descriptor[13])), .cfg_dilation_j(CFG_WIDTH'(descriptor[14])),
    .cfg_input_base(MEM_ADDR_WIDTH'(descriptor[15])),
    .cfg_kernel_base(MEM_ADDR_WIDTH'(descriptor[16])),
    .cfg_output_base(MEM_ADDR_WIDTH'(descriptor[17])),
    .cfg_quantize(descriptor[18][0]), .cfg_output_shift(descriptor[19][4:0]),
    .cfg_round_nearest(descriptor[20][0]), .cfg_output_multiplier(descriptor[23]),
    .cfg_bias_enable(descriptor[24][0]), .cfg_bias_base(MEM_ADDR_WIDTH'(descriptor[25])),
    .cfg_relu_enable(descriptor[26][0]),
    .mem_re(layer_mem_re), .mem_raddr(layer_mem_raddr), .mem_rdata(mem_rdata),
    .mem_we(mem_we), .mem_waddr(mem_waddr), .mem_wdata(mem_wdata)
  );
endmodule

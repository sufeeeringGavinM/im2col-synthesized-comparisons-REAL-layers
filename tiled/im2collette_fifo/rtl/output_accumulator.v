`timescale 1ns / 1ps

// Address and data generation for per-tap output writeback and read-modify-write accumulation
// OUTPUT WRITEBACK: store each completed spatial result, then reuse it next pass.
// writeback_cnt tracks pipeline progress; wb_ptr tracks actual output SRAM words.
// The two counters differ because fill/drain cycles do not all produce results.
// accumulate selects old stored sum + new pass result; otherwise overwrite it.
// The read address leads a write by one cycle to align synchronous old_out data.
// CHANNEL_INDEX/COL_INDEX selects an output filter column, not an input channel.
module output_accumulator #(
    parameter integer CHANNEL_INDEX = 0,
    parameter integer ACC_WIDTH     = 32,
    parameter integer ADDR_WIDTH    = 8,
    parameter integer WB_CNT_WIDTH  = 33,
    parameter integer OUT_LATENCY   = 11,
    parameter integer CFG_WIDTH     = 32
) (
    input  wire                     clk,
    input  wire                     clear,
    input  wire                     advance,
    input  wire                     writeback_active,
    input  wire                     stream_enable,
    input  wire                     accumulate,
    input  wire [CFG_WIDTH-1:0]     output_pixels,
    input  wire [ACC_WIDTH-1:0]     old_out,
    input  wire [ACC_WIDTH-1:0]     result_in,
    output wire                     wb_valid,
    output reg  [ADDR_WIDTH-1:0]    wb_ptr,
    output wire [ADDR_WIDTH-1:0]    wb_ptr_next,
    output wire [ACC_WIDTH-1:0]     wb_data
);

    // First valid result reaches this column after row skew + array/output latency.
    localparam integer WB_START_CYCLE = CHANNEL_INDEX + OUT_LATENCY;

    // Counts pass progress; variants with advance increment only when the array moves.
    reg [WB_CNT_WIDTH-1:0] writeback_cnt;
    always @(posedge clk) begin
        if (clear) writeback_cnt <= {WB_CNT_WIDTH{1'b0}};
        else if (advance) writeback_cnt <= writeback_cnt + 1'b1;
    end

    assign wb_valid = advance && writeback_active && stream_enable &&
                      (writeback_cnt >= WB_START_CYCLE) &&
                      (writeback_cnt - WB_START_CYCLE < output_pixels);

    always @(posedge clk) begin
        if (clear) wb_ptr <= {ADDR_WIDTH{1'b0}};
        else if (wb_valid) wb_ptr <= wb_ptr + 1'b1;
    end

    // Prefetch the next old output sum one synchronous-read cycle before writeback.
    assign wb_ptr_next = clear ? {ADDR_WIDTH{1'b0}} : (wb_valid ? wb_ptr + 1'b1 : wb_ptr);
    // First reduction pass overwrites; later passes add to the previously stored sum.
    assign wb_data = accumulate ? (old_out + result_in) : result_in;

endmodule
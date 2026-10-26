`timescale 1ns/1ps
// Two vector slots overlap bank service, read return and array consumption.
// BUILD COMPLETE ACTIVATION VECTORS FROM SINGLE-READ-PORT BANKS.
// Each array row requests lane_bank/lane_addr. Serve one distinct word per bank
// per cycle; identical bank+address requests can share that read. Lowest row wins
// when distinct words compete. Unserved requests remain pending for retry.
// Two data slots decouple bank service/read returns from array consumption.
// These slots hold values, unlike im2col_addr_gen's separate address-seed sets.
module banked_input #(parameter ARRAY_SIZE=4, BIT_WIDTH=8, ADDR_WIDTH=8, CFG_WIDTH=32,
    BANK_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1)) (
    input clk, clear, running,
    input [CFG_WIDTH-1:0] output_pixels,
    output reg [CFG_WIDTH-1:0] issue_position,
    input [ARRAY_SIZE-1:0] lane_valid,
    input [ARRAY_SIZE-1:0][BANK_WIDTH-1:0] lane_bank,
    input [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] lane_addr,
    input consume,
    output vector_ready,
    output [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] vector_data,
    input [ARRAY_SIZE-1:0] we_ext,
    input [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] waddr_ext,
    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] wdata_ext,
    output conflict_retry,
    output [ARRAY_SIZE-1:0] bank_read_enable,
    output issue_advance
);
  // issue_slot is the vector being assembled; read_slot is next to consume.
  // occupied reserves a slot; ready says every required read has returned.
  // active says the current vector still has requests pending from a conflict.
  reg issue_slot, read_slot, active;
  reg [1:0] occupied, ready;
  reg [ARRAY_SIZE-1:0] pending;
  reg [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] values [0:1];
  // grant marks requests scheduled this cycle. response_* delays their row,
  // bank and destination slot identity to match the synchronous SRAM return.
  // response_final marks the final set of reads, not immediate readiness.
  reg [ARRAY_SIZE-1:0] grant, response_valid;
  reg [ARRAY_SIZE-1:0][BANK_WIDTH-1:0] response_bank;
  reg response_slot, response_final;
  reg [ARRAY_SIZE-1:0] read_enable;
  reg [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] read_addr;
  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] read_data;
  assign vector_ready = ready[read_slot];
  assign vector_data = values[read_slot];
  // A slot can be reused on the same edge that its old vector is consumed.
  wire slot_available = !occupied[issue_slot] || (consume && read_slot==issue_slot);
  wire issue_enable = running && issue_position < output_pixels && (active || slot_available);
  wire [ARRAY_SIZE-1:0] requests = active ? pending : lane_valid;
  integer b, i;
  always @* begin
    grant = 0; read_enable = 0; read_addr = 0;
    if (issue_enable) begin
      // Lowest row wins. Requests for the same bank word share one read.
      for (i=0; i<ARRAY_SIZE; i=i+1) begin
        if (requests[i]) begin
          if (!read_enable[lane_bank[i]]) begin
            read_enable[lane_bank[i]] = 1;
            read_addr[lane_bank[i]] = lane_addr[i];
            grant[i] = 1;
          end else if (read_addr[lane_bank[i]] == lane_addr[i]) grant[i] = 1;
        end
      end
    end
  end
  assign bank_read_enable = read_enable;
  // Count an actual remaining request, rather than an assumed conflict penalty.
  assign conflict_retry = issue_enable && |(requests & ~grant);
  genvar bank;
  generate for (bank=0; bank<ARRAY_SIZE; bank=bank+1) begin : g_bank
    input_bank #(.BIT_WIDTH(BIT_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_bank (
      .clk(clk),.read_enable(read_enable[bank]),.raddr(read_addr[bank]),
      .we(we_ext[bank]),.waddr(waddr_ext[bank]),.wdata(wdata_ext[bank]),.rdata(read_data[bank]));
  end endgenerate
  integer row;
  // The address producer advances only after all requests have been ISSUED.
  // Their returns and subsequent array consumption can occur on later edges.
  assign issue_advance = issue_enable && ((requests & ~grant)==0);
  always @(posedge clk) begin
    if (clear) begin
      issue_position <= 0;
      issue_slot <= 0; read_slot <= 0; active <= 0;
      occupied <= 0; ready <= 0; pending <= 0;
      response_valid <= 0; response_final <= 0;
      response_slot <= 0; response_bank <= 0;
      values[0] <= 0; values[1] <= 0;
    end else begin
      // Release the old head. Later assignments can reserve the same slot on
      // this edge when a new vector is simultaneously admitted.
      if (consume) begin
        ready[read_slot] <= 0;
        occupied[read_slot] <= 0;
        read_slot <= !read_slot;
      end
      // Previous edge's bank reads return after one synchronous read latency.
      for (row=0; row<ARRAY_SIZE; row=row+1)
        if (response_valid[row]) values[response_slot][row] <= read_data[response_bank[row]];
      // Only the last read RETURN makes the assembled vector consumable.
      if (response_final) ready[response_slot] <= 1;
      response_valid <= grant;
      response_slot <= issue_slot;
      response_bank <= lane_bank;
      response_final <= 0;
      if (issue_enable) begin
        if (!active) begin
          occupied[issue_slot] <= 1;
          ready[issue_slot] <= 0;
          values[issue_slot] <= 0;
        end
        // Preserve only conflicting requests; already served rows are not reread.
        pending <= requests & ~grant;
        if ((requests & ~grant)==0) begin
          active <= 0;
          issue_slot <= !issue_slot;
          issue_position <= issue_position+1'b1;
          // An all-padding/unused vector needs no SRAM return, so zero is ready now.
          if (grant==0) ready[issue_slot] <= 1;
          else response_final <= 1;
        end else active <= 1;
      end
    end
  end
endmodule

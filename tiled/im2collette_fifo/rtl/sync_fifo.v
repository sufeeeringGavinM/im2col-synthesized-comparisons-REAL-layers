`timescale 1ns / 1ps

// PACKET QUEUE: registered writes/pointers/count, combinational head-word output.
// wr_ptr selects the next write slot; rd_ptr selects the oldest unread slot.
// status_cnt distinguishes empty/full even when pointers are equal. Simultaneous
// accepted push and pop advance both pointers and leave the count unchanged.
// Pointer overflow wraps naturally; the instantiated queue depth is a power of two.
// Reset empties the queue by resetting metadata, rather than clearing every word.
module sync_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 8,
    parameter integer ADDR_WIDTH = 3  // 2^3 = 8 
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  full,
    output wire                  empty,
    output wire [ADDR_WIDTH:0]   count
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   status_cnt;

    assign full  = (status_cnt == DEPTH);
    assign empty = (status_cnt == 0);
    assign count = status_cnt;

    // Head data is continuously visible. empty/packet_ready determines whether
    // it is meaningful; reading dout itself does not pop the queue.
    assign dout = mem[rd_ptr];

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr     <= {ADDR_WIDTH{1'b0}};
            rd_ptr     <= {ADDR_WIDTH{1'b0}};
            status_cnt <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            // Accept enables using the pre-edge full/empty flags. A simultaneous pop
            // does not admit a write when already full; the producer waits for space.
            // 10=push, 01=pop, 11=both, 00=hold.
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr + 1'b1;
                    status_cnt  <= status_cnt + 1'b1;
                end
                2'b01: begin
                    rd_ptr      <= rd_ptr + 1'b1;
                    status_cnt  <= status_cnt - 1'b1;
                end
                2'b11: begin
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr + 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule
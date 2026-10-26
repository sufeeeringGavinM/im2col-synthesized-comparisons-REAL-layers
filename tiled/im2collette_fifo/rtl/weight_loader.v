`timescale 1ns / 1ps

// Prefetch and descending row shifts for the initial or next kernel tap
module weight_loader #(
    parameter integer ARRAY_SIZE = 10,
    parameter integer BIT_WIDTH  = 8,
    parameter integer ADDR_WIDTH = 8,
    parameter integer CFG_WIDTH  = 32
) (
    input  wire                                           clk,
    input  wire                                           nrst,
    input  wire                                           restart,
    input  wire                                           prime,
    input  wire                                           initial_load,
    input  wire                                           preload_next,
    input  wire                                           running,
    input  wire                                           active_weight_buffer,
    input  wire [CFG_WIDTH-1:0]                           R, S, r, s, next_r, next_s,
    input  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0]          kernel_rdata,
    output wire                                           load_weights,
    output wire                                           weight_write_buffer,
    output wire                                           initial_done,
    output wire                                           kernel_read_enable,
    output wire [ADDR_WIDTH-1:0]                          kernel_raddr,
    output wire [CFG_WIDTH-1:0]                           c_read,
    output wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0]          weight_row_in
);

    localparam integer C_WIDTH = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1;
    localparam [1:0] PREFETCH      = 2'd0,
                     SHIFT_WEIGHTS = 2'd1,
                     WEIGHTS_READY = 2'd2;

    reg [1:0] weight_phase;
    reg [C_WIDTH-1:0] c_load;

    assign load_weights = initial_load || (preload_next && (weight_phase == SHIFT_WEIGHTS));
    assign weight_write_buffer = running ? !active_weight_buffer : active_weight_buffer;
    assign initial_done = (c_load == 0);

    wire [C_WIDTH-1:0] read_row = (load_weights && (c_load != 0)) ? (c_load - 1'b1) : c_load;
    assign c_read = CFG_WIDTH'(read_row);

    wire [CFG_WIDTH-1:0] kernel_r = running ? next_r : r;
    wire [CFG_WIDTH-1:0] kernel_s = running ? next_s : s;

    assign kernel_read_enable = prime || initial_load || (preload_next && (weight_phase != WEIGHTS_READY));
  // Row-address counter follows the existing descending channel read sequence.
  reg [CFG_WIDTH-1:0] tap_index,saved_r,saved_s;
  reg [ADDR_WIDTH-1:0] row_address;
  wire [CFG_WIDTH-1:0] kernel_stride=R*S;
  wire tap_changed=r!=saved_r || s!=saved_s;
  wire [CFG_WIDTH-1:0] current_tap=tap_index+(tap_changed ? 1'b1 : 1'b0);
  wire [CFG_WIDTH-1:0] selected_tap=running ? current_tap+1'b1 : current_tap;
  wire [ADDR_WIDTH-1:0] highest_address=ADDR_WIDTH'((ARRAY_SIZE-1)*kernel_stride+selected_tap);
  wire first_read=prime || (preload_next && weight_phase==PREFETCH);
  assign kernel_raddr=first_read ? highest_address : load_weights && c_load!=0 ? row_address-ADDR_WIDTH'(kernel_stride) : row_address;
  always @(posedge clk) begin
    if(!nrst || (restart && !running)) begin
      tap_index<=0;saved_r<=0;saved_s<=0;row_address<=0;
    end else begin
      if(tap_changed) begin tap_index<=current_tap;saved_r<=r;saved_s<=s;end
      if(first_read) row_address<=highest_address;
      else if(load_weights && c_load!=0) row_address<=row_address-ADDR_WIDTH'(kernel_stride);
    end
  end
    assign weight_row_in = load_weights ? kernel_rdata : {ARRAY_SIZE*BIT_WIDTH{1'b0}};

    always @(posedge clk) begin
        if (!nrst || restart) begin
            c_load       <= C_WIDTH'(ARRAY_SIZE - 1);
            weight_phase <= PREFETCH;
        end else if (initial_load) begin
            if (initial_done) begin
                c_load       <= C_WIDTH'(ARRAY_SIZE - 1);
                weight_phase <= PREFETCH;
            end else begin
                c_load <= c_load - 1'b1;
            end
        end else if (preload_next) begin
            case (weight_phase)
                PREFETCH: weight_phase <= SHIFT_WEIGHTS;
                SHIFT_WEIGHTS: begin
                    if (c_load == 0) weight_phase <= WEIGHTS_READY;
                    else             c_load <= c_load - 1'b1;
                end
                WEIGHTS_READY: begin end
                default: weight_phase <= PREFETCH;
            endcase
        end
    end

endmodule
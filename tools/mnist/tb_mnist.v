// Adapted from validated tb_conv_chain: actual memory handoffs, no golden injection.
// AI assistance: Codex. Backing memory is a simulation model, not FPGA memory RTL.
`timescale 1ns/1ps
module tb_mnist;
  parameter HOST_RELU=1;
  real clock_half_ns=5;
  initial if($value$plusargs("CLOCK_HALF_NS=%f",clock_half_ns)) begin end
  reg clk=0,nrst=0,descriptor_valid=0,descriptor_last;
  always #(clock_half_ns) clk=~clk;
  wire descriptor_ready,busy,done,chain_busy,chain_done,mem_re,mem_we;
  reg [31:0] cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q;
  reg [31:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j;
  reg [31:0] cfg_input_base,cfg_kernel_base,cfg_output_base;
  reg cfg_quantize,cfg_round_nearest,cfg_bias_enable;
  reg [4:0] cfg_output_shift;
  reg [31:0] cfg_output_multiplier,cfg_bias_base;
  wire [31:0] mem_raddr,mem_waddr,mem_wdata;
  reg [31:0] mem_rdata;
  reg [31:0] memory[0:199999],expected[0:5999],expected_post[0:5999],descriptors[0:80];
  integer layer_count=2;
  integer writes[0:5999];
  integer layer,j,off=0,base,outputs,cycles=0,accepted=0,started;
  integer live_input,live_words,live_output,live_outputs;
  integer phase[0:15],reads_count,writes_count,jobs,core_busy_count,phase_total;
  integer dump;
  string init_file,desc_file,expected_file,post_file;
  integer raw_dump,post_clamps=0;
  time window_start_time,window_end_time;
  integer power_stage=0;
  conv_chain DUT(.*);
  always @(posedge clk) begin
    cycles<=cycles+1;
    if(nrst) begin
      if(descriptor_valid && descriptor_ready) begin
        accepted<=accepted+1;
        live_input<=cfg_input_base;live_words<=cfg_N*cfg_C*cfg_H*cfg_W;
        live_output<=cfg_output_base;live_outputs<=cfg_N*cfg_K*cfg_P*cfg_Q;
      end
      if(busy) begin
        phase[DUT.u_accelerator.state] <= phase[DUT.u_accelerator.state]+1;
        if(DUT.u_accelerator.core_busy) core_busy_count<=core_busy_count+1;
        if(DUT.u_accelerator.state==8) jobs<=jobs+1;
      end
      if(mem_re) begin
        if($isunknown(mem_raddr)||mem_raddr>=200000)$fatal(1,"Bad chain read");
        mem_rdata<=memory[mem_raddr];reads_count<=reads_count+1;
      end
      if(mem_we) begin
        if($isunknown(mem_waddr)||mem_waddr<live_output||mem_waddr>=live_output+live_outputs)$fatal(1,"Bad chain output address");
        if(mem_waddr>=live_input && mem_waddr<live_input+live_words)$fatal(1,"Overwrote live input");
        if($isunknown(mem_wdata))$fatal(1,"Unknown completed output");
        memory[mem_waddr]<=mem_wdata;
        writes[mem_waddr-live_output]<=writes[mem_waddr-live_output]+1;
        writes_count<=writes_count+1;
      end
      if(busy && descriptor_ready)$fatal(1,"Descriptor accepted while busy");
    end
  end
  initial begin
    if($value$plusargs("LAYERS=%d",layer_count)) begin end
    if(layer_count<1 || layer_count>3)$fatal(1,"Unsupported layer count");
    if(!$value$plusargs("INIT=%s",init_file)||!$value$plusargs("DESC=%s",desc_file)||!$value$plusargs("EXPECTED=%s",expected_file))$fatal(1,"Missing fixture");
    $readmemh(init_file,memory);$readmemh(desc_file,descriptors);$readmemh(expected_file,expected);
    if(!$value$plusargs("POST=%s",post_file))$fatal(1,"Missing post-ReLU reference");
    $readmemh(post_file,expected_post);
    dump=$fopen("rtl_outputs.hex","w");
    raw_dump=$fopen("raw_outputs.hex","w");
    repeat(3)@(negedge clk);nrst=1;
    for(layer=0;layer<layer_count;layer=layer+1) begin
      @(negedge clk);
      for(j=0;j<16;j=j+1)phase[j]=0;
      for(j=0;j<6000;j=j+1)writes[j]=0;
      reads_count=0;writes_count=0;jobs=0;core_busy_count=0;
      {cfg_N,cfg_C,cfg_H,cfg_W,cfg_K,cfg_R,cfg_S,cfg_P,cfg_Q,
       cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,
       cfg_input_base,cfg_kernel_base,cfg_output_base}=
      {descriptors[layer*27],descriptors[layer*27+1],descriptors[layer*27+2],descriptors[layer*27+3],descriptors[layer*27+4],descriptors[layer*27+5],descriptors[layer*27+6],descriptors[layer*27+7],descriptors[layer*27+8],descriptors[layer*27+9],descriptors[layer*27+10],descriptors[layer*27+11],descriptors[layer*27+12],descriptors[layer*27+13],descriptors[layer*27+14],descriptors[layer*27+15],descriptors[layer*27+16],descriptors[layer*27+17]};
      cfg_quantize=descriptors[layer*27+18];cfg_output_shift=descriptors[layer*27+19];
      cfg_round_nearest=descriptors[layer*27+20];descriptor_last=descriptors[layer*27+21];
      cfg_output_multiplier=descriptors[layer*27+23];
      cfg_bias_enable=descriptors[layer*27+24];cfg_bias_base=descriptors[layer*27+25];
      base=cfg_output_base;outputs=descriptors[layer*27+22];
      wait(descriptor_ready);descriptor_valid=1;@(posedge clk);started=cycles;
      if(layer==0) begin window_start_time=$time; power_stage=1; end
      @(negedge clk);descriptor_valid=0;
      // Verify captured controls; attempted busy handshakes must be ignored.
      cfg_bias_enable=~cfg_bias_enable;
      cfg_bias_base=199999;cfg_input_base=199999;cfg_output_base=199999;cfg_C=0;
      cfg_output_multiplier=32'hdeadbeef;cfg_quantize=~cfg_quantize;
      cfg_output_shift=31;cfg_round_nearest=~cfg_round_nearest;descriptor_last=~descriptor_last;
      repeat(3)@(negedge clk);descriptor_valid=1;
      repeat(3)@(negedge clk);descriptor_valid=0;
      wait(done);
      if(layer==layer_count-1) begin window_end_time=$time; power_stage=2; end
      #1;
      if(chain_done!==(layer==layer_count-1)||!chain_busy)$fatal(1,"Chain completion mismatch");
      if(writes_count!=outputs)$fatal(1,"Wrong completed write count");
      for(j=0;j<outputs;j=j+1) begin
        if(writes[j]!=1)$fatal(1,"Missing/duplicate completed output");
        if(memory[base+j]!==expected[off+j])$fatal(1,"Layer%0d output%0d want%h got%h",layer,j,expected[off+j],memory[base+j]);
        $fdisplay(raw_dump,"%08x",memory[base+j]);
        // Processor-offload stand-in: transform actual RTL writes, never goldens.
        // No simulated time is assigned; CPU offload latency/energy is unmeasured.
        if(HOST_RELU && descriptors[layer*27+26] && memory[base+j][31]) begin
          memory[base+j]=0;post_clamps=post_clamps+1;
        end
        if(memory[base+j]!==expected_post[off+j])$fatal(1,"Post-ReLU mismatch");
        $fdisplay(dump,"%08x",memory[base+j]);
      end
      phase_total=0;for(j=0;j<16;j=j+1)phase_total=phase_total+phase[j];
      $display("LAYER_PASS layer=%0d outputs=%0d cycles=%0d phases=%0d reads=%0d writes=%0d jobs=%0d core_busy=%0d",layer,outputs,cycles-started-1,phase_total,reads_count,writes_count,jobs,core_busy_count);
      for(j=0;j<16;j=j+1)$display("PHASE layer=%0d state=%0d cycles=%0d",layer,j,phase[j]);
      off=off+outputs;@(negedge clk);
    end
    repeat(2)@(negedge clk);
    if(chain_busy||accepted!=layer_count)$fatal(1,"Descriptor count or busy incorrect");
    $fclose(dump);$fclose(raw_dump);
    $display("POST_CLAMPS %0d",post_clamps);
    $display("CHAIN_WINDOW_NS %0t",window_end_time-window_start_time);
    power_stage=3;
    $display("PASS: matched %0d-layer pipeline, exact raw/post outputs and captured controls",layer_count);$finish;
  end
  initial begin repeat(3000000)@(posedge clk);$fatal(1,"Watchdog");end
endmodule

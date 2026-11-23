// Exercise the memory-backed top with real layer handoffs. AI assistance: Codex.
`timescale 1ns/1ps
module tb_mnist_program;
  reg clk=0, nrst=0, start=0;
  reg [31:0] program_base;
  wire chain_busy, chain_done, mem_re, mem_we;
  wire [31:0] mem_raddr, mem_waddr, mem_wdata;
  reg [31:0] mem_rdata;
  reg [31:0] memory[0:199999], expected_post[0:5999], descriptors[0:107];
  integer fixture_base, active_base, layer_count, layer, trial, trials, j;
  integer off, base, outputs, live_input, live_words;
  integer writes[0:5999], phase[0:15];
  integer accepted, finished, fetch_reads, reads_count, writes_count, jobs, core_busy_count, phase_total;
  integer dump, raw_dump;
  string init_file, desc_file, post_file;
  real clock_half_ns=5;
  realtime window_start_time, window_end_time;
  integer power_stage=0;

  conv_program DUT(.*);
  wire busy = DUT.busy, done = DUT.done;
  wire accept = DUT.descriptor_valid && DUT.descriptor_ready;

  initial if ($value$plusargs("CLOCK_HALF_NS=%f",clock_half_ns)) begin end
  always #(clock_half_ns) clk=~clk;

  always @(posedge clk) if (nrst) begin
    if (accept) begin
      if (!chain_busy || accepted != layer || fetch_reads != (layer+1)*27)
        $fatal(1,"Layer accepted out of order or before complete fetch");
      accepted <= accepted+1;
    end
    if (chain_done)
      finished <= finished+1;
    if (busy) begin
      phase[DUT.u_chain.u_accelerator.state] <= phase[DUT.u_chain.u_accelerator.state]+1;
      if (DUT.u_chain.u_accelerator.core_busy) core_busy_count <= core_busy_count+1;
      if (DUT.u_chain.u_accelerator.state==8) jobs <= jobs+1;
    end
    if (mem_re) begin
      if ($isunknown(mem_raddr) || mem_raddr>=200000) $fatal(1,"Bad memory read");
      mem_rdata <= memory[mem_raddr];
      if (DUT.fetching) begin
        if (!chain_busy || busy || mem_we || fetch_reads>=layer_count*27 ||
            mem_raddr!==32'(active_base+fetch_reads))
          $fatal(1,"Bad descriptor fetch at word %0d",fetch_reads);
        fetch_reads <= fetch_reads+1;
      end else begin
        if (!busy || (mem_raddr>=active_base && mem_raddr<active_base+layer_count*27))
          $fatal(1,"Bad tensor read or descriptor/data overlap");
        reads_count <= reads_count+1;
      end
    end
    if (mem_we) begin
      if (!busy || $isunknown(mem_waddr) || mem_waddr<base || mem_waddr>=base+outputs)
        $fatal(1,"Bad chain output address");
      if ((mem_waddr>=live_input && mem_waddr<live_input+live_words) ||
          (mem_waddr>=active_base && mem_waddr<active_base+layer_count*27))
        $fatal(1,"Overwrote live input or program");
      if ($isunknown(mem_wdata)) $fatal(1,"Unknown completed output");
      memory[mem_waddr] <= mem_wdata;
      writes[mem_waddr-base] <= writes[mem_waddr-base]+1;
      writes_count <= writes_count+1;
    end
  end

  initial begin
    if (!$value$plusargs("LAYERS=%d",layer_count) || layer_count<1 || layer_count>4)
      $fatal(1,"Unsupported layer count");
    if (!$value$plusargs("INIT=%s",init_file) || !$value$plusargs("DESC=%s",desc_file) ||
        !$value$plusargs("POST=%s",post_file) || !$value$plusargs("PROGRAM_BASE=%d",fixture_base))
      $fatal(1,"Missing fixture");
    $readmemh(init_file,memory);
    $readmemh(desc_file,descriptors,0,layer_count*27-1);
    $readmemh(post_file,expected_post);
    trials = $test$plusargs("RESTART") ? 2 : 1;
    if (trials==2) begin
      // The second launch uses a different program address and the same tensors.
      for (j=0;j<layer_count*27;j=j+1) memory[fixture_base+128+j]=descriptors[j];
    end
    dump=$fopen("rtl_outputs.hex","w");
    raw_dump=$fopen("raw_outputs.hex","w");

    repeat (3) @(negedge clk);
    nrst=1;
    for (trial=0;trial<trials;trial=trial+1) begin
      accepted=0;
      finished=0;
      fetch_reads=0;
      off=0;
      active_base=fixture_base+trial*128;
      program_base=active_base;
      start=1;
      @(posedge clk);
      window_start_time=$realtime; power_stage=1;
      @(negedge clk);
      if (!chain_busy) $fatal(1,"Busy did not cover initial descriptor fetch");
      start=0;
      program_base=199999;
      // An extra pulse with a different base during fetch must be ignored.
      @(negedge clk); start=1;
      @(negedge clk); start=0;
      for (layer=0;layer<layer_count;layer=layer+1) begin
        base=descriptors[layer*27+17];
        outputs=descriptors[layer*27+22];
        live_input=descriptors[layer*27+15];
        live_words=descriptors[layer*27]*descriptors[layer*27+1]*
                   descriptors[layer*27+2]*descriptors[layer*27+3];
        for (j=0;j<16;j=j+1) phase[j]=0;
        for (j=0;j<outputs;j=j+1) writes[j]=0;
        reads_count=0; writes_count=0; jobs=0; core_busy_count=0;
        wait (done);
        if (layer==layer_count-1) begin
          wait (chain_done);
          window_end_time=$realtime; power_stage=2;
        end
        @(negedge clk);
        if (chain_done!==(layer==layer_count-1) || !chain_busy || accepted!=layer+1)
          $fatal(1,"Bad chain completion or launch count");
        if (writes_count!=outputs) $fatal(1,"Wrong completed write count");
        for (j=0;j<outputs;j=j+1) begin
          if (writes[j]!=1 || memory[base+j]!==expected_post[off+j])
            $fatal(1,"Layer %0d output %0d want %h got %h writes %0d",
                   layer,j,expected_post[off+j],memory[base+j],writes[j]);
          if (trial==0) begin
            $fdisplay(raw_dump,"%08x",memory[base+j]);
            $fdisplay(dump,"%08x",memory[base+j]);
          end
        end
        if (trial==0) begin
          phase_total=0;
          for (j=0;j<16;j=j+1) phase_total=phase_total+phase[j];
          $display("LAYER_PASS layer=%0d outputs=%0d cycles=%0d phases=%0d reads=%0d writes=%0d jobs=%0d core_busy=%0d",
                   layer,outputs,phase_total,phase_total,reads_count,writes_count,jobs,core_busy_count);
          for (j=0;j<16;j=j+1) $display("PHASE layer=%0d state=%0d cycles=%0d",layer,j,phase[j]);
        end
        off=off+outputs;
        @(negedge clk);
      end
      if (chain_busy || chain_done || finished!=1 || fetch_reads!=27*layer_count)
        $fatal(1,"Bad final status or descriptor read count");
      if (trial==0) begin
        $display("DESCRIPTOR_READS %0d",fetch_reads);
        $display("CHAIN_WINDOW_NS %0d",longint'((window_end_time-window_start_time)*1000.0));
      end
    end
    $fclose(dump); $fclose(raw_dump);
    $display("POST_CLAMPS 0");
    if (trials==2) $display("RESTART_PASS");
    power_stage=3;
    $display("PASS: matched %0d-layer pipeline with memory-resident descriptors",layer_count);
    $finish;
  end
  initial begin repeat (3000000) @(posedge clk); $fatal(1,"Watchdog"); end
endmodule

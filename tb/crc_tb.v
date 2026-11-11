`timescale 1ns/1ps

module crc16_tb;

    reg         clk;
    reg         rst_n;
    reg         start;
    reg         bit_valid;
    reg         data_bit;
    reg         last_bit;
    reg  [15:0] expected_crc;
    wire        busy;
    wire [15:0] crc_result;
    wire        match;
    wire        done;

    crc16_checker dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .bit_valid   (bit_valid),
        .data_bit    (data_bit),
        .last_bit    (last_bit),
        .expected_crc(expected_crc),
        .busy        (busy),
        .crc_result  (crc_result),
        .match       (match),
        .done        (done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function [31:0] lfsr_next;
        input [31:0] x;
    begin
        lfsr_next = {x[30:0], 1'b0} ^ ({32{x[31]}} & 32'hB400_0000);
    end
    endfunction

    integer     err_cnt;
    integer     pkt_cnt;
    integer     idx;
    reg [31:0]  lfsr;
    reg [255:0] pkt;
    reg [15:0]  rcrc;
    reg [15:0]  prev_res;
    reg         prev_match;
    reg [15:0]  ref_crc;
    reg         ref_fb;
    reg         sp_stall;

    task ref_compute;
        input  [255:0] bit_stream;
        input  [31:0]  num_bits;
        output [15:0]  crc_out;
        integer        k;
    begin
        ref_crc = 16'hFFFF;
        for (k = 0; k < num_bits; k = k + 1) begin
            ref_fb  = ref_crc[15] ^ bit_stream[255 - k];
            ref_crc = {ref_crc[14:0], 1'b0};
            if (ref_fb) ref_crc = ref_crc ^ 16'h1021;
        end
        crc_out = ref_crc;
    end
    endtask

    task gen_pkt;
        integer w;
    begin
        for (w = 0; w < 8; w = w + 1) begin
            lfsr = lfsr_next(lfsr);
            pkt  = {pkt[223:0], lfsr};
        end
    end
    endtask

    task apply_reset;
        input [31:0] n;
        integer k;
    begin
        rst_n        = 1'b0;
        start        = 1'b0;
        bit_valid    = 1'b0;
        data_bit     = 1'b0;
        last_bit     = 1'b0;
        expected_crc = 16'h0000;
        for (k = 0; k < n; k = k + 1) @(posedge clk);
        #1;
        rst_n      = 1'b1;
        prev_res   = 16'h0000;
        prev_match = 1'b0;
    end
    endtask

    task fail;
        input [31:0] id;
        input [8*48-1:0] msg;
    begin
        $display("ERROR [T\%0d] t=\%0t : \%0s", id, $time, msg);
        err_cnt = err_cnt + 1;
    end
    endtask

    task send_packet;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  exp_crc;
        input [2:0]   mode;
        input [31:0]  id;
        integer       j;
    begin
        start        = 1'b1;
        expected_crc = exp_crc;
        if (mode[1]) begin
            bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b1;
        end else begin
            bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
        end
        @(posedge clk); #1;
        start        = 1'b0;
        expected_crc = ~exp_crc;
        bit_valid    = 1'b0; data_bit = 1'b0; last_bit = 1'b0;

        if (busy !== 1'b1)             fail(id, "busy not high after start");
        if (done !== 1'b0)             fail(id, "done high after start");
        if (crc_result !== prev_res)   fail(id, "crc_result changed at start");
        if (match !== prev_match)      fail(id, "match changed at start");

        for (j = 0; j < n_bits; j = j + 1) begin
            if (mode[0]) begin
                lfsr     = lfsr_next(lfsr);
                sp_stall = (lfsr[1:0] != 2'b00);
            end else begin
                sp_stall = 1'b0;
            end
            while (sp_stall) begin
                bit_valid = 1'b0;
                if (mode[1]) begin
                    data_bit = lfsr[4];
                    last_bit = lfsr[5] | lfsr[6];
                end else begin
                    data_bit = 1'b0;
                    last_bit = 1'b0;
                end
                @(posedge clk); #1;
                if (busy !== 1'b1)           fail(id, "busy dropped during stall");
                if (done !== 1'b0)           fail(id, "done during stall");
                if (crc_result !== prev_res) fail(id, "crc_result changed in stall");
                if (match !== prev_match)    fail(id, "match changed in stall");
                lfsr     = lfsr_next(lfsr);
                sp_stall = (lfsr[1:0] == 2'b11);
            end

            bit_valid = 1'b1;
            data_bit  = bits[255 - j];
            last_bit  = (j == n_bits - 1) ? 1'b1 : 1'b0;
            if (mode[2] && (n_bits >= 4) && (j == (n_bits >> 1)))
                start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            if (j < n_bits - 1) begin
                if (busy !== 1'b1)           fail(id, "busy dropped mid-packet");
                if (done !== 1'b0)           fail(id, "done mid-packet");
                if (crc_result !== prev_res) fail(id, "crc_result changed mid-packet");
                if (match !== prev_match)    fail(id, "match changed mid-packet");
            end
        end
        bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
    end
    endtask

    task check_packet;
        input [15:0] ref_val;
        input        exp_match;
        input [31:0] id;
    begin
        pkt_cnt = pkt_cnt + 1;
        if (done !== 1'b1)             fail(id, "done not asserted");
        if (busy !== 1'b0)             fail(id, "busy still high after last bit");
        if (crc_result !== ref_val) begin
            $display("       crc_result=%04h  reference=%04h", crc_result, ref_val);
            fail(id, "crc_result != reference");
        end
        if (match !== exp_match)       fail(id, "match wrong");
        prev_res   = ref_val;
        prev_match = exp_match;
    end
    endtask

    task check_done_drop;
        input [31:0] id;
    begin
        @(posedge clk); #1;
        if (done !== 1'b0)             fail(id, "done longer than 1 cycle");
        if (busy !== 1'b0)             fail(id, "busy high while idle");
        if (crc_result !== prev_res)   fail(id, "crc_result did not hold");
        if (match !== prev_match)      fail(id, "match did not hold");
    end
    endtask

    task run_packet;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  exp_crc;
        input [2:0]   mode;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        send_packet(bits, n_bits, exp_crc, mode, id);
        check_packet(r, (exp_crc == r), id);
        check_done_drop(id);
    end
    endtask

    task run_good;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [2:0]   mode;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        run_packet(bits, n_bits, r, mode, id);
    end
    endtask

    task idle_noise;
        input [31:0] cycles;
        input [31:0] id;
        integer k;
    begin
        for (k = 0; k < cycles; k = k + 1) begin
            lfsr      = lfsr_next(lfsr);
            start     = 1'b0;
            bit_valid = 1'b1;
            data_bit  = lfsr[3];
            last_bit  = 1'b1;
            @(posedge clk); #1;
            if (busy !== 1'b0)           fail(id, "busy rose without start");
            if (done !== 1'b0)           fail(id, "done rose while idle");
            if (crc_result !== prev_res) fail(id, "crc_result changed while idle");
            if (match !== prev_match)    fail(id, "match changed while idle");
        end
        bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
    end
    endtask

    task known;
        input [255:0] bits;
        input [31:0]  n_bits;
        input [15:0]  known_crc;
        input [31:0]  id;
        reg   [15:0]  r;
    begin
        ref_compute(bits, n_bits, r);
        if (r !== known_crc) begin
            $display("       ref model=%04h  known=%04h", r, known_crc);
            fail(id, "reference model != known answer");
        end
        run_packet(bits, n_bits, known_crc, 3'b000, id);
    end
    endtask

    initial begin
        err_cnt    = 0;
        pkt_cnt    = 0;
        lfsr       = 32'hDEAD_BEEF;
        pkt        = 256'h0;
        prev_res   = 16'h0000;
        prev_match = 1'b0;
        start = 1'b0; bit_valid = 1'b0; data_bit = 1'b0; last_bit = 1'b0;
        expected_crc = 16'h0000;
        rst_n = 1'b0;

        $display("=== T0: reset sanity ===");
        apply_reset(4);
        if (busy !== 1'b0 || done !== 1'b0 || match !== 1'b0 || crc_result !== 16'h0000)
            fail(0, "outputs not cleared by reset");
        @(posedge clk); #1;

        $display("=== T1: known answers ===");
        pkt = 256'h0; pkt[255:184] = 72'h31_32_33_34_35_36_37_38_39;
        known(pkt, 32'd72, 16'h29B1, 1);
        pkt = 256'h0; pkt[255:248] = 8'h41;
        known(pkt, 32'd8,  16'hB915, 1);
        pkt = 256'h0; pkt[255:240] = 16'h4142;
        known(pkt, 32'd16, 16'h4B74, 1);
        pkt = 256'h0; pkt[255:248] = 8'h00;
        known(pkt, 32'd8,  16'hE1F0, 1);
        pkt = 256'h0; pkt[255:248] = 8'hFF;
        known(pkt, 32'd8,  16'hFF00, 1);

        $display("=== T2: 1-bit packets ===");
        pkt = 256'h0; pkt[255] = 1'b1;  run_good(pkt, 32'd1, 3'b000, 2);
        pkt = 256'h0; pkt[255] = 1'b0;  run_good(pkt, 32'd1, 3'b000, 2);
        pkt = 256'h0; pkt[255] = 1'b1;  run_good(pkt, 32'd1, 3'b010, 2);

        $display("=== T3: lengths 1..40 ===");
        for (idx = 1; idx <= 40; idx = idx + 1) begin
            gen_pkt;
            run_good(pkt, idx, 3'b000, 3);
        end

        $display("=== T4: stalls + junk, lengths 1..40 ===");
        for (idx = 1; idx <= 40; idx = idx + 1) begin
            gen_pkt;
            run_good(pkt, idx, 3'b011, 4);
        end

        $display("=== T5: long packets ===");
        gen_pkt; run_good(pkt, 32'd64,  3'b011, 5);
        gen_pkt; run_good(pkt, 32'd72,  3'b001, 5);
        gen_pkt; run_good(pkt, 32'd128, 3'b011, 5);
        gen_pkt; run_good(pkt, 32'd256, 3'b011, 5);

        $display("=== T6: wrong expected_crc ===");
        gen_pkt;
        ref_compute(pkt, 32'd24, rcrc);
        for (idx = 0; idx < 16; idx = idx + 1)
            run_packet(pkt, 32'd24, rcrc ^ (16'h0001 << idx), 3'b000, 6);
        run_packet(pkt, 32'd24, ~rcrc, 3'b000, 6);
        run_packet(pkt, 32'd24, rcrc,  3'b000, 6);

        $display("=== T7: idle noise ===");
        idle_noise(10, 7);
        gen_pkt; run_good(pkt, 32'd12, 3'b000, 7);
        idle_noise(10, 7);

        $display("=== T8: start while busy ===");
        for (idx = 4; idx <= 24; idx = idx + 4) begin
            gen_pkt;
            run_good(pkt, idx, 3'b100, 8);
            gen_pkt;
            run_good(pkt, idx, 3'b111, 8);
        end

        $display("=== T9: back-to-back ===");
        gen_pkt;
        ref_compute(pkt, 32'd16, rcrc);
        send_packet(pkt, 32'd16, rcrc, 3'b000, 9);
        check_packet(rcrc, 1'b1, 9);
        pkt = 256'h0; pkt[255:248] = 8'h55;
        ref_compute(pkt, 32'd8, rcrc);
        send_packet(pkt, 32'd8, rcrc, 3'b000, 9);
        check_packet(rcrc, 1'b1, 9);
        pkt = 256'h0; pkt[255:248] = 8'hAA;
        ref_compute(pkt, 32'd8, rcrc);
        send_packet(pkt, 32'd8, ~rcrc, 3'b000, 9);
        check_packet(rcrc, 1'b0, 9);
        check_done_drop(9);

        $display("=== T10: all-zeros / all-ones ===");
        pkt = 256'h0;                                     run_good(pkt, 32'd16, 3'b000, 10);
        pkt = 256'h0;                                     run_good(pkt, 32'd33, 3'b011, 10);
        pkt = {256{1'b1}};                                run_good(pkt, 32'd16, 3'b000, 10);
        pkt = {256{1'b1}};                                run_good(pkt, 32'd33, 3'b011, 10);

        $display("=== T11: reset during packet ===");
        gen_pkt; run_good(pkt, 32'd20, 3'b000, 11);

        start = 1'b1; expected_crc = 16'h1234;
        @(posedge clk); #1;
        start = 1'b0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            bit_valid = 1'b1; data_bit = idx[0]; last_bit = 1'b0;
            @(posedge clk); #1;
        end
        rst_n = 1'b0; bit_valid = 1'b0;
        @(posedge clk); #1;
        rst_n = 1'b1;
        prev_res = 16'h0000; prev_match = 1'b0;
        if (busy !== 1'b0 || done !== 1'b0 || crc_result !== 16'h0000 || match !== 1'b0)
            fail(11, "reset did not clear outputs");
        @(posedge clk); #1;
        gen_pkt; run_good(pkt, 32'd17, 3'b011, 11);

        start = 1'b1; expected_crc = 16'hABCD;
        @(posedge clk); #1;
        start = 1'b0;
        bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b0; @(posedge clk); #1;
        bit_valid = 1'b1; data_bit = 1'b0; last_bit = 1'b0; @(posedge clk); #1;
        rst_n = 1'b0; bit_valid = 1'b1; data_bit = 1'b1; last_bit = 1'b1;
        @(posedge clk); #1;
        rst_n = 1'b1; bit_valid = 1'b0; last_bit = 1'b0; data_bit = 1'b0;
        prev_res = 16'h0000; prev_match = 1'b0;
        if (busy !== 1'b0 || done !== 1'b0 || crc_result !== 16'h0000 || match !== 1'b0)
            fail(11, "reset on last-bit cycle published a result");
        @(posedge clk); #1;
        if (done !== 1'b0) fail(11, "done after reset-on-last-bit");
        gen_pkt; run_good(pkt, 32'd9, 3'b000, 11);

        #20;
        $display("-----------------------------------------");
        $display("packets checked : %0d", pkt_cnt);
        if (err_cnt == 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d ERRORS DETECTED ***", err_cnt);
        $display("-----------------------------------------");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT: simulation exceeded 20 ms");
        $finish;
    end

endmodule

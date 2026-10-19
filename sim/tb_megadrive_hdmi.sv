`timescale 1ns/10ps
module tb_megadrive_hdmi #(
    parameter SAMPLES_PER_PACKET = 1
);
    reg clk = 0, clk_pixel = 0, clk_serial = 0, resetn = 0;
    always #4.94 clk = ~clk;
    always #8.55 clk_pixel = ~clk_pixel;
    always #1.71 clk_serial = ~clk_serial;
    GSR GSR (.GSRI(resetn));
    reg enable = 1;
    reg [10:0] x = 0;
    reg [9:0] y = 0;
    wire clk_audio;
    wire signed [15:0] sample_left, sample_right;
    reg signed [19:0] audio_left = 0, audio_right = 0;
    audio_sampler_48k #(.CLOCK_HZ(53_740_385)) sampler (
        .clk_sys(clk), .resetn(resetn), .audio_left(audio_left), .audio_right(audio_right),
        .clk_audio(clk_audio), .sample_left(sample_left), .sample_right(sample_right)
    );
    dvi_tx #(.HDMI_AUDIO(1), .SERIAL_RESET_SYNC(1), .H_TOTAL(988),
             .ACTIVE_X(0), .ACTIVE_Y(0), .AUDIO_SAMPLES_PER_PACKET(SAMPLES_PER_PACKET),
             .PREAMBLE_NEXT_LINE(1), .AUDIO_ACR_COUNTER_BITS(15)) dut (
        .clk_pix(clk_pixel), .clk_pix5(clk_serial), .resetn(resetn),
        .r(8'h12), .g(8'h34), .b(8'h56), .de(x < 640 && y < 480),
        .hsync(x >= 664 && x < 760), .vsync(y >= 490 && y < 496),
        .pix_x(x), .pix_y(y), .frame_height(10'd524),
        .audio_enable(enable), .clk_audio(clk_audio), .audio_left(sample_left), .audio_right(sample_right)
    );
    always @(negedge clk_pixel) begin
        if (!resetn) begin x = 0; y = 0; end
        else if (x == 987) begin x = 0; y = y == 523 ? 0 : y + 1'b1; end
        else x = x + 1'b1;
    end
    integer cycles = 0, generated = 0, received = 0, last_cycle = 0;
    integer packets = 0, acr_packets = 0, info_packets = 0, avi_packets = 0;
    integer sample_index;
    wire default_clk_audio;
    audio_sampler_48k default_sampler (
        .clk_sys(clk), .resetn(resetn), .audio_left(audio_left), .audio_right(audio_right),
        .clk_audio(default_clk_audio), .sample_left(), .sample_right()
    );
    integer default_last_cycle = 0;
    always @(posedge default_clk_audio) begin
        if (default_last_cycle != 0 && cycles - default_last_cycle != 900)
            $fatal(1,"default 43.2MHz sampler changed");
        default_last_cycle = cycles;
    end
    reg [15:0] expected_left [0:2047], expected_right [0:2047];
    always @(negedge clk) begin
        cycles = cycles + 1;
        audio_left = (generated + 1) << 4;
        audio_right = -(generated + 1) <<< 4;
    end
    always @(posedge clk_audio) begin
        #1;
        if (generated != 0 && cycles - last_cycle != 1119 && cycles - last_cycle != 1120)
            $fatal(1,"HDMI sample rate interval%0d expected1119/1120 clocks",cycles-last_cycle);
        last_cycle = cycles;
        expected_left[generated] = sample_left;
        expected_right[generated] = sample_right;
        generated = generated + 1;
    end
    function [7:0] ecc(input [55:0] data, input integer bits);
        integer index;
        reg [7:0] value;
        begin
            value = 0;
            for (index = 0; index < bits; index = index + 1)
                value = (value >> 1) ^ ((value[0] ^ data[index]) ? 8'h83 : 8'h00);
            ecc = value;
        end
    endfunction
    function [7:0] info_sum(input [23:0] header, input [55:0] payload);
        integer index;
        reg [7:0] total;
        begin
            total = header[7:0] + header[15:8] + header[23:16];
            for (index = 0; index < 7; index = index + 1)
                total = total + payload[index*8 +: 8];
            info_sum = total;
        end
    endfunction
    always @(negedge clk_pixel) begin
        #1;
        if (resetn && dut.hdmi_audio_on) begin
        if (x < 640 && y < 480 && dut.mode != 1) $fatal(1,"HDMI corrupts active video at%0d/%0d",x,y);
        if (dut.video_preamble && !(x >= 978 && x < 986 && (y < 479 || y == 523)))
            $fatal(1,"video preamble geometry");
        if (dut.island_period && (x < 654 || x >= 782)) $fatal(1,"island geometry");
        if (dut.island_period && dut.g_hdmi_audio.u_audio_packets.packet_counter == 0) begin
            packets = packets + 1;
            case (dut.packet_header[7:0])
                2: begin
                    if (dut.packet_header[11:8] != (1 << SAMPLES_PER_PACKET) - 1)
                        $fatal(1,"sample presence flags");
                    if (dut.packet_header[23:20] != (received % 192 == 0 ? 1 : 0))
                        $fatal(1,"IEC sample block start flag");
                    for (sample_index = 0; sample_index < SAMPLES_PER_PACKET; sample_index = sample_index + 1) begin
                        if (received >= generated ||
                            dut.packet_sub[sample_index][23:8] !== expected_left[received] ||
                            dut.packet_sub[sample_index][47:32] !== expected_right[received])
                            $fatal(1,"stereo samples lost/reordered sample%0d generated%0d",received,generated);
                        if (^{dut.packet_sub[sample_index][51:48],dut.packet_sub[sample_index][23:0]} ||
                            ^{dut.packet_sub[sample_index][55:52],dut.packet_sub[sample_index][47:24]})
                            $fatal(1,"sample parity");
                        received = received + 1;
                    end
                end
                1: begin
                    acr_packets = acr_packets + 1;
                    if (dut.g_hdmi_audio.u_audio_packets.acr_cycle_stamp < 31048 ||
                        dut.g_hdmi_audio.u_audio_packets.acr_cycle_stamp > 31052)
                        $fatal(1,"CTS must represent 31.05MHz /48kHz, got%0d",
                               dut.g_hdmi_audio.u_audio_packets.acr_cycle_stamp);
                end
                8'h84: begin
                    if (info_sum(dut.packet_header,dut.packet_sub[0]) != 0 ||
                        dut.packet_sub[0][10:8] != 1)
                        $fatal(1,"stereo audio infoframe checksum/channel count");
                    info_packets = info_packets + 1;
                end
                8'h82: begin
                    if (info_sum(dut.packet_header,dut.packet_sub[0]) != 0)
                        $fatal(1,"AVI infoframe checksum");
                    avi_packets = avi_packets + 1;
                end
                default: ;
            endcase
        end
        if (dut.island_period && dut.g_hdmi_audio.u_audio_packets.packet_counter == 28) begin
            if (dut.g_hdmi_audio.u_audio_packets.parity0 !== ecc(dut.packet_sub[0],56) ||
                dut.g_hdmi_audio.u_audio_packets.parity1 !== ecc(dut.packet_sub[1],56) ||
                dut.g_hdmi_audio.u_audio_packets.parity2 !== ecc(dut.packet_sub[2],56) ||
                dut.g_hdmi_audio.u_audio_packets.parity3 !== ecc(dut.packet_sub[3],56) ||
                dut.g_hdmi_audio.u_audio_packets.parity4 !== ecc({32'b0,dut.packet_header},24))
                $fatal(1,"HDMI packet BCH parity");
        end
        end
    end
    initial begin
        repeat (10) @(negedge clk); resetn = 1;
        // More than one complete video frame, including the blank-to-active preamble.
        repeat (1_119_600) @(negedge clk);
        if (generated != 1000 || received < generated - 2 * SAMPLES_PER_PACKET || acr_packets < 19 ||
            info_packets < 2 || avi_packets < 2)
            $fatal(1,"audio throughput gen%0d recv%0d acr%0d info%0d avi%0d",
                   generated,received,acr_packets,info_packets,avi_packets);
        enable = 0;
        repeat (10) @(negedge clk_pixel);
        if (dut.hdmi_audio_on || dut.island_period || dut.video_preamble)
            $fatal(1,"HDMI audio off does not restore DVI mode");
        resetn = 0;
        repeat (10) @(negedge clk_pixel);
        if (sample_left !== 0 || sample_right !== 0) $fatal(1,"sampler reset");
        $display("PASS Mega Drive HDMI: 48kHz stereo, no dropped samples, ACR/info/AVI, IEC flags, BCH, timing and output toggle");
        $finish;
    end
    initial begin #30000000; $fatal(1,"timeout"); end
endmodule

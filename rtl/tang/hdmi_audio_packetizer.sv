// HDMI 1.4 audio packets for the Tang Nano 20K.
// Packet organization follows HDMI 1.4a; the packet scheduling approach was
// informed by NESTang's GPLv3 HDMI transmitter by Sameer Puri.
module hdmi_audio_packetizer (
    input  wire               clk_pixel,
    input  wire               resetn,
    input  wire               audio_enable,
    input  wire               clk_audio,
    input  wire signed [15:0] sample_left,
    input  wire signed [15:0] sample_right,
    input  wire               packet_start,
    input  wire               packet_period,
    input  wire               video_field_end,
    output reg  [23:0]         header,
    output reg  [55:0]         sub [3:0],
    output wire [8:0]          packet_data
);

localparam [2:0] PACKET_NULL  = 3'd0;
localparam [2:0] PACKET_ACR   = 3'd1;
localparam [2:0] PACKET_AUDIO = 3'd2;
localparam [2:0] PACKET_INFO  = 3'd3;
localparam [2:0] PACKET_AVI   = 3'd4;

reg [2:0] packet_type;
reg [1:0] audio_clock_sync;
reg       audio_clock_delayed;
wire      audio_rising = audio_clock_sync[1] && !audio_clock_delayed;

reg [15:0] sample_l [1:0][3:0];
reg [15:0] sample_r [1:0][3:0];
reg        sample_write_bank;
reg        sample_read_bank;
reg [1:0]  sample_write_index;
reg [1:0]  sample_ready;
reg [7:0]  audio_frame_counter;

reg [5:0]  acr_audio_count;
reg [14:0] acr_cycle_count;
reg [19:0] acr_cycle_stamp;
reg        acr_pending;
reg        audio_info_sent;
reg        avi_info_sent;

reg [7:0] parity0, parity1, parity2, parity3, parity4;
reg [4:0] packet_counter;

wire [19:0] acr_n = 20'd6144;
wire [55:0] acr_sub = {
    acr_n[7:0], acr_n[15:8], 4'd0, acr_n[19:16],
    acr_cycle_stamp[7:0], acr_cycle_stamp[15:8],
    4'd0, acr_cycle_stamp[19:16], 8'd0
};

wire [63:0] bch0 = {parity0, sub[0]};
wire [63:0] bch1 = {parity1, sub[1]};
wire [63:0] bch2 = {parity2, sub[2]};
wire [63:0] bch3 = {parity3, sub[3]};
wire [31:0] bch4 = {parity4, header};
wire [5:0] packet_bit_pair = {packet_counter, 1'b0};
wire [5:0] packet_bit_pair_next = {packet_counter, 1'b1};

assign packet_data = {
    bch3[packet_bit_pair_next], bch2[packet_bit_pair_next],
    bch1[packet_bit_pair_next], bch0[packet_bit_pair_next],
    bch3[packet_bit_pair], bch2[packet_bit_pair],
    bch1[packet_bit_pair], bch0[packet_bit_pair],
    bch4[packet_counter]
};

function [7:0] ecc_next;
    input [7:0] ecc;
    input       next_bit;
    begin
        ecc_next = (ecc >> 1) ^
                   ((ecc[0] ^ next_bit) ? 8'b10000011 : 8'd0);
    end
endfunction

wire [7:0] p0_next = ecc_next(parity0, sub[0][packet_bit_pair]);
wire [7:0] p1_next = ecc_next(parity1, sub[1][packet_bit_pair]);
wire [7:0] p2_next = ecc_next(parity2, sub[2][packet_bit_pair]);
wire [7:0] p3_next = ecc_next(parity3, sub[3][packet_bit_pair]);
wire [7:0] p0_next2 = ecc_next(p0_next, sub[0][packet_bit_pair_next]);
wire [7:0] p1_next2 = ecc_next(p1_next, sub[1][packet_bit_pair_next]);
wire [7:0] p2_next2 = ecc_next(p2_next, sub[2][packet_bit_pair_next]);
wire [7:0] p3_next2 = ecc_next(p3_next, sub[3][packet_bit_pair_next]);
wire [7:0] p4_next = ecc_next(parity4, header[packet_counter]);

function status_bit;
    input [7:0] frame_bit;
    input       right_channel;
    begin
        case (frame_bit)
            8'd2:  status_bit = 1'b1;                    // consumer PCM
            8'd20: status_bit = !right_channel;          // channel number
            8'd21: status_bit = right_channel;
            8'd25: status_bit = 1'b1;                    // 48 kHz
            8'd33: status_bit = 1'b1;                    // 16-bit samples
            default: status_bit = 1'b0;
        endcase
    end
endfunction

integer i;
reg [7:0] frame_bit;
reg [3:0] sample_starts;
reg [23:0] left_word;
reg [23:0] right_word;
reg left_status;
reg right_status;
reg left_parity;
reg right_parity;

always @* begin
    header = 24'd0;
    for (i = 0; i < 4; i = i + 1)
        sub[i] = 56'd0;

    case (packet_type)
        PACKET_ACR: begin
            header = 24'h000001;
            for (i = 0; i < 4; i = i + 1)
                sub[i] = acr_sub;
        end
        PACKET_AUDIO: begin
            sample_starts = 4'b0000;
            for (i = 0; i < 4; i = i + 1) begin
                frame_bit = audio_frame_counter + i;
                if (frame_bit >= 8'd192)
                    frame_bit = frame_bit - 8'd192;
                sample_starts[i] = (frame_bit == 8'd0);
            end
            header = {sample_starts, 8'b00000000, 4'b1111, 8'd2};
            for (i = 0; i < 4; i = i + 1) begin
                frame_bit = audio_frame_counter + i;
                if (frame_bit >= 8'd192)
                    frame_bit = frame_bit - 8'd192;
                left_word = {sample_l[sample_read_bank][i], 8'd0};
                right_word = {sample_r[sample_read_bank][i], 8'd0};
                left_status = status_bit(frame_bit, 1'b0);
                right_status = status_bit(frame_bit, 1'b1);
                left_parity = ^{left_status, 1'b0, 1'b0, left_word};
                right_parity = ^{right_status, 1'b0, 1'b0, right_word};
                sub[i] = {
                    right_parity, right_status, 1'b0, 1'b0,
                    left_parity, left_status, 1'b0, 1'b0,
                    right_word, left_word
                };
            end
        end
        PACKET_INFO: begin
            header = 24'h0A0184;
            sub[0] = {8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd1, 8'h70};
        end
        PACKET_AVI: begin
            header = 24'h0D0282;
            sub[0] = {8'd0, 8'd0, 8'd0, 8'h80, 8'h18, 8'd0, 8'hD7};
        end
        default: begin
            header = 24'd0;
        end
    endcase
end

always @(posedge clk_pixel) begin
    audio_clock_sync     <= {audio_clock_sync[0], clk_audio};
    audio_clock_delayed  <= audio_clock_sync[1];

    if (!resetn || !audio_enable) begin
        audio_clock_sync    <= 2'b00;
        audio_clock_delayed <= 1'b0;
        sample_write_bank  <= 1'b0;
        sample_read_bank   <= 1'b0;
        sample_write_index <= 2'd0;
        sample_ready       <= 2'b00;
        audio_frame_counter <= 8'd0;
        acr_audio_count    <= 6'd0;
        acr_cycle_count    <= 15'd0;
        acr_cycle_stamp    <= 20'd0;
        acr_pending        <= 1'b0;
        audio_info_sent    <= 1'b0;
        avi_info_sent      <= 1'b0;
        packet_type        <= PACKET_NULL;
    end else begin
        acr_cycle_count <= acr_cycle_count + 15'd1;

        if (audio_rising) begin
            if (!sample_ready[sample_write_bank]) begin
                sample_l[sample_write_bank][sample_write_index] <= sample_left;
                sample_r[sample_write_bank][sample_write_index] <= sample_right;
                if (sample_write_index == 2'd3) begin
                    sample_ready[sample_write_bank] <= 1'b1;
                    sample_write_bank <= !sample_write_bank;
                    sample_write_index <= 2'd0;
                end else begin
                    sample_write_index <= sample_write_index + 2'd1;
                end
            end

            if (acr_audio_count == 6'd47) begin
                acr_audio_count <= 6'd0;
                acr_cycle_stamp <= {5'd0, acr_cycle_count + 15'd1};
                acr_cycle_count <= 15'd0;
                acr_pending <= 1'b1;
            end else begin
                acr_audio_count <= acr_audio_count + 6'd1;
            end
        end

        if (video_field_end) begin
            audio_info_sent <= 1'b0;
            avi_info_sent <= 1'b0;
        end

        if (packet_period && packet_counter == 5'd31 &&
            packet_type == PACKET_AUDIO)
            audio_frame_counter <= audio_frame_counter + 8'd4 >= 8'd192 ?
                                   audio_frame_counter - 8'd188 :
                                   audio_frame_counter + 8'd4;

        if (packet_start) begin
            if (acr_pending) begin
                packet_type <= PACKET_ACR;
                acr_pending <= 1'b0;
            end else if (sample_ready[sample_read_bank]) begin
                packet_type <= PACKET_AUDIO;
                sample_ready[sample_read_bank] <= 1'b0;
                sample_read_bank <= !sample_read_bank;
            end else if (!audio_info_sent) begin
                packet_type <= PACKET_INFO;
                audio_info_sent <= 1'b1;
            end else if (!avi_info_sent) begin
                packet_type <= PACKET_AVI;
                avi_info_sent <= 1'b1;
            end else begin
                packet_type <= PACKET_NULL;
            end
        end
    end
end

always @(posedge clk_pixel) begin
    if (!resetn || !audio_enable || !packet_period) begin
        packet_counter <= 5'd0;
        parity0 <= 8'd0;
        parity1 <= 8'd0;
        parity2 <= 8'd0;
        parity3 <= 8'd0;
        parity4 <= 8'd0;
    end else begin
        packet_counter <= packet_counter + 5'd1;
        if (packet_counter < 5'd28) begin
            parity0 <= p0_next2;
            parity1 <= p1_next2;
            parity2 <= p2_next2;
            parity3 <= p3_next2;
            if (packet_counter < 5'd24)
                parity4 <= p4_next;
        end else if (packet_counter == 5'd31) begin
            parity0 <= 8'd0;
            parity1 <= 8'd0;
            parity2 <= 8'd0;
            parity3 <= 8'd0;
            parity4 <= 8'd0;
        end
    end
end

endmodule

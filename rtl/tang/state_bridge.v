module state_bridge #(
    parameter SUPPORTED = 1
) (
    input wire clk,
    input wire resetn,
    input wire core_reset,
    input wire safe_to_hold,
    input wire valid,
    input wire [1:0] address,
    input wire [31:0] write_data,
    input wire [3:0] write_strobe,
    output reg ready,
    output reg [31:0] read_data,
    output reg hold_core,
    output reg state_write,
    output reg [19:0] state_address,
    output reg [31:0] state_data,
    input wire [31:0] state_q,
    output reg [22:0] raw_base
);
reg hold_requested;
reg [6:0] settling;
reg [2:0] phase;
reg [1:0] active_address;
reg [31:0] read_stage;
always @(posedge clk) begin
    ready <= 0;
    state_write <= 0;
    if (!resetn) begin
        hold_core <= 0;
        hold_requested <= 0;
        settling <= 0;
        phase <= 0;
        state_address <= 0;
        state_data <= 0;
        raw_base <= 0;
        read_data <= 0;
        read_stage <= 0;
        active_address <= 0;
    end else begin
        if (core_reset) begin
            hold_core <= 0;
            hold_requested <= 0;
            settling <= 0;
        end else if (!hold_requested) begin
            hold_core <= 0;
            settling <= 0;
        end else if (!hold_core && safe_to_hold) begin
            hold_core <= 1;
            settling <= 80;
        end else if (settling != 0) begin
            settling <= settling - 1'b1;
        end
        case (phase)
            0: if (valid) begin
                active_address <= address;
                phase <= 1;
                if (|write_strobe) begin
                    case (address)
                        0: hold_requested <= SUPPORTED && !core_reset && write_data[0];
                        1: state_address <= write_data[19:0];
                        2: if (hold_core && settling == 0) begin
                            state_data <= write_data;
                            state_write <= 1;
                        end
                        3: raw_base <= write_data[22:0];
                    endcase
                end
            end
            1: phase <= 2;
            2: begin
                case (active_address)
                    0: read_stage <= {16'h5353, 7'd0, (SUPPORTED != 0), 7'd0,
                                     hold_core && settling == 0};
                    1: read_stage <= {12'd0, state_address};
                    2: read_stage <= SUPPORTED ? state_q : 32'd0;
                    3: read_stage <= {9'd0, raw_base};
                endcase
                phase <= 3;
            end
            3: begin read_data <= read_stage; ready <= 1; phase <= 4; end
            4: phase <= 0;
            default: phase <= 0;
        endcase
    end
end
endmodule
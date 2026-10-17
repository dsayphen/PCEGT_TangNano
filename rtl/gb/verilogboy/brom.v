`timescale 1ns / 1ps
`default_nettype wire

module brom(
    input  wire [7:0] a,
    output reg  [7:0] d
);

always @(*) begin
    case (a)
        // 0x0000: ld sp, $fffe (31 fe ff)
        8'h00: d = 8'h31;
        8'h01: d = 8'hFE;
        8'h02: d = 8'hFF;
        // 0x0003: ld hl, $014d (21 4d 01)
        8'h03: d = 8'h21;
        8'h04: d = 8'h4D;
        8'h05: d = 8'h01;
        // 0x0006: ld c, $13 (0e 13)
        8'h06: d = 8'h0E;
        8'h07: d = 8'h13;
        // 0x0008: ld e, $d8 (1e d8)
        8'h08: d = 8'h1E;
        8'h09: d = 8'hD8;
        // 0x000A: ld a, $91 (3e 91)
        8'h0A: d = 8'h3E;
        8'h0B: d = 8'h91;
        // 0x000C: ldh [$40], a (LCDC = 0x91) (e0 40)
        8'h0C: d = 8'hE0;
        8'h0D: d = 8'h40;
        // 0x000E: ld a, $e4 (3e e4)
        8'h0E: d = 8'h3E;
        8'h0F: d = 8'hE4;
        // 0x0010: ldh [$47], a (BGP = 0xe4) (e0 47)
        8'h10: d = 8'hE0;
        8'h11: d = 8'h47;
        // 0x0012: jp $00fc (c3 fc 00)
        8'h12: d = 8'hC3;
        8'h13: d = 8'hFC;
        8'h14: d = 8'h00;

        // At 0x00FC:
        // 0x00FC: ld a, $01 (3e 01)
        8'hFC: d = 8'h3E;
        8'hFD: d = 8'h01;
        // 0x00FE: ldh [$50], a (e0 50)
        // Disables bootrom during this instruction.
        // When execution finishes, PC increments to $0100.
        // Opcode fetch at $0100 is > 0x00FF and goes directly to Cartridge ROM!
        8'hFE: d = 8'hE0;
        8'hFF: d = 8'h50;

        default: d = 8'h00; // NOP
    endcase
end

endmodule

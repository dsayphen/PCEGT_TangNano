`timescale 1ns/1ps

// Drives the physical SNES pad pins of the NES+GB top and checks the NES
// $4016/$4017 serial data seen by the core.
module tb_nes_gamepad;
    reg clk = 0;
    reg [11:0] buttons = 0;     // 1 = pressed, SNES order B,Y,Sel,Start,U,D,L,R,A,X,L,R
    reg overlay = 0;
    reg [2:0] strobe = 0;
    reg [1:0] read_clock = 0;
    reg [15:0] pad_shift = 16'hffff;
    integer button_index;
    reg [7:0] expected;

    wire pad_bit = pad_shift[0];

    always #5 clk = ~clk;

    top_tang_nano20k_nesgb dut ();

    // SNES controller model: active-low serial data, loaded on LATCH,
    // advanced on each rising CLK edge, 1 after the 16th bit.
    always @(posedge dut.pad_latch)
        pad_shift <= {4'hf, ~buttons};
    always @(posedge dut.pad_clk)
        if (!dut.pad_latch)
            pad_shift <= {1'b1, pad_shift[15:1]};

    task check(input condition, input [511:0] message);
        if (condition !== 1'b1) begin
            $display("FAIL: %0s", message);
            $fatal(1);
        end
    endtask

    task wait_pad(input [11:0] value);
        integer timeout;
        begin
            timeout = 0;
            while (dut.pad_buttons !== value && timeout < 40000) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(dut.pad_buttons === value, "SNES pad scan must report the pressed buttons");
        end
    endtask

    task latch_buttons;
        begin
            @(negedge clk);
            strobe = 1;
            repeat (3) @(negedge clk);
            strobe = 0;
        end
    endtask

    task read_buttons(input [7:0] value);
        integer serial_index;
        reg serial_value;
        begin
            for (serial_index = 0; serial_index < 10; serial_index = serial_index + 1) begin
                serial_value = serial_index < 8 ? value[serial_index] : 1'b1;
                check(dut.joypad1_data === {4'b0000, serial_value},
                      "port 1 serial bit and inactive expansion lines");
                check((|dut.joypad1_data[1:0]) === serial_value,
                      "Famicom-compatible read must match standard NES read");
                check(dut.joypad2_data === 5'b00000,
                      "unconnected port 2 must report no buttons");
                read_clock = 1;
                repeat (3) @(negedge clk);
                check(dut.joypad1_data[0] === serial_value,
                      "serial data remains stable throughout the read");
                read_clock = 0;
                repeat (3) @(negedge clk);
            end
        end
    endtask

    initial begin
        force dut.mclk = clk;
        force dut.sys_resetn = 1'b1;
        force dut.pad_data = pad_bit;
        force dut.osd_active = overlay;
        force dut.joypad_out = strobe;
        force dut.joypad_clock = read_clock;

        wait_pad(12'h000);
        latch_buttons;
        read_buttons(8'h00);

        for (button_index = 0; button_index < 12; button_index = button_index + 1) begin
            buttons = 12'b1 << button_index;
            expected = 0;
            if (button_index < 8)
                expected[button_index] = 1;
            else if (button_index == 8)
                expected[0] = 1;
            else if (button_index == 9)
                expected[1] = 1;
            wait_pad(buttons);
            latch_buttons;
            read_buttons(expected);
        end

        buttons = 12'hfff;
        wait_pad(buttons);
        latch_buttons;
        read_buttons(8'hff);

        overlay = 1;
        latch_buttons;
        read_buttons(8'h00);
        overlay = 0;
        latch_buttons;
        read_buttons(8'hff);

        $display("tb_nes_gamepad PASSED");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "controller test timed out");
    end
endmodule

module tb_cheat_protocol;
    reg clk = 1'b0;
    reg resetn = 1'b0;
    reg ctrl_write = 1'b0;
    reg [31:0] ctrl_data = 32'b0;
    reg addr_write = 1'b0;
    reg [31:0] addr_data = 32'b0;
    reg value_write = 1'b0;
    reg [31:0] value_data = 32'b0;
    reg push_write = 1'b0;
    reg [31:0] push_data = 32'b0;
    reg [20:0] cpu_addr = 21'b0;
    reg [7:0] cpu_data = 8'h12;
    wire apply_enable;
    wire codes_reset;
    wire [128:0] code_bus;
    wire available;
    wire override;
    wire [7:0] replacement;

    always #5 clk = ~clk;

    cheat_mmio mmio (
        .clk(clk), .resetn(resetn),
        .ctrl_write(ctrl_write), .ctrl_data(ctrl_data),
        .addr_write(addr_write), .addr_data(addr_data),
        .value_write(value_write), .value_data(value_data),
        .push_write(push_write), .push_data(push_data),
        .apply_enable(apply_enable), .codes_reset(codes_reset),
        .code_bus(code_bus)
    );

        CODES #(.ADDR_WIDTH(21), .DATA_WIDTH(8), .MAX_CODES(32),
            .COMPARE_SUPPORT(0)) engine (
        .clk(clk), .reset(codes_reset), .enable(apply_enable),
        .available(available), .addr_in(cpu_addr), .data_in(cpu_data),
        .code(code_bus), .genie_ovr(override), .genie_data(replacement)
    );

    task write_register;
        input integer reg_id;
        input [31:0] data;
        begin
            @(negedge clk);
            case (reg_id)
                0: begin ctrl_write = 1; ctrl_data = data; end
                1: begin addr_write = 1; addr_data = data; end
                2: begin value_write = 1; value_data = data; end
                3: begin push_write = 1; push_data = data; end
            endcase
            @(negedge clk);
            ctrl_write = 0;
            addr_write = 0;
            value_write = 0;
            push_write = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1'b1;
        write_register(0, 2);
        if (!codes_reset || apply_enable)
            $fatal(1, "clear must pulse reset and keep application disabled");
        @(negedge clk);
        if (codes_reset)
            $fatal(1, "reset pulse must last one clock");

        write_register(1, 32'h001f0dbc);
        write_register(2, 32'h00000099);
        write_register(3, 1);
        repeat (3) @(posedge clk);
        if (!available || code_bus[84:64] !== 21'h1f0dbc ||
            code_bus[7:0] !== 8'h99 || code_bus[96] !== 1'b0)
            $fatal(1, "patch fields or rising-edge insertion are incorrect");

        write_register(1, 32'h001f1410);
        write_register(2, 32'h000000b0);
        write_register(3, 1);
        repeat (3) @(posedge clk);
        if (code_bus[84:64] !== 21'h1f1410 || code_bus[7:0] !== 8'hb0)
            $fatal(1, "second patch was not transferred");

        cpu_addr = 21'h1f0dbc;
        write_register(0, 1);
        #1;
        if (!override || replacement !== 8'h99)
            $fatal(1, "active patch did not override the matching CPU read");
        cpu_addr = 21'h1f1410;
        #1;
        if (!override || replacement !== 8'hb0)
            $fatal(1, "second active patch did not override its CPU read");

        write_register(0, 0);
        #1;
        if (override)
            $fatal(1, "GG_EN polarity did not disable patch application");

        write_register(0, 2);
        repeat (2) @(posedge clk);
        if (available)
            $fatal(1, "GG_RESET did not clear the code slots");
        $display("ok: cheat MMIO clear, patch strobe, data, enable polarity");
        $finish;
    end
endmodule
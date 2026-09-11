//
// Test bench for rom_source_arb: exactly one loader may reach the SDRAM write
// port, the ROM description must always describe the image that is actually
// in memory, and the loser of the arbitration must be told the port is busy.
//
`timescale 1ns/1ps

module tb_rom_source_arb;

reg clk = 0;
reg resetn = 0;
always #11.574 clk = ~clk;

reg        rv_ld_wr = 0, rv_loading = 0, rv_image_valid = 0;
reg [22:0] rv_ld_addr = 0, rv_rom_offset = 0;
reg [7:0]  rv_ld_data = 0, rv_rom_sz = 0;
reg        rv_sgx_mode = 0;
wire       rv_ld_busy;

reg        ua_ld_wr = 0, ua_loading = 0, ua_image_valid = 0;
reg [22:0] ua_ld_addr = 0, ua_rom_offset = 0;
reg [7:0]  ua_ld_data = 0, ua_rom_sz = 0;
reg        ua_sgx_mode = 0;
wire       ua_ld_busy;

wire        ld_wr;
wire [22:0] ld_addr, rom_offset;
wire [7:0]  ld_data, rom_sz;
reg         ld_busy = 0;
wire        loading, image_valid, own_uart, sgx_mode;

rom_source_arb dut (
    .clk(clk), .resetn(resetn),
    .rv_ld_wr(rv_ld_wr), .rv_ld_addr(rv_ld_addr), .rv_ld_data(rv_ld_data),
    .rv_loading(rv_loading), .rv_image_valid(rv_image_valid),
    .rv_rom_sz(rv_rom_sz), .rv_rom_offset(rv_rom_offset),
    .rv_sgx_mode(rv_sgx_mode), .rv_ld_busy(rv_ld_busy),
    .ua_ld_wr(ua_ld_wr), .ua_ld_addr(ua_ld_addr), .ua_ld_data(ua_ld_data),
    .ua_loading(ua_loading), .ua_image_valid(ua_image_valid),
    .ua_rom_sz(ua_rom_sz), .ua_rom_offset(ua_rom_offset),
    .ua_sgx_mode(ua_sgx_mode), .ua_ld_busy(ua_ld_busy),
    .ld_wr(ld_wr), .ld_addr(ld_addr), .ld_data(ld_data), .ld_busy(ld_busy),
    .loading(loading), .image_valid(image_valid),
    .rom_sz(rom_sz), .rom_offset(rom_offset), .sgx_mode(sgx_mode),
    .own_uart_o(own_uart)
);

integer errors = 0;

task chk;
    input cond;
    input [255:0] name;
    begin
        if (!cond) begin
            $display("FAIL %0s", name);
            errors = errors + 1;
        end else
            $display("ok   %0s", name);
    end
endtask

// A write from a source that does not own the port must never appear on the
// aggregate strobe together with the owner's data.
always @(posedge clk) begin
    if (ld_wr) begin
        if (own_uart) begin
            if (ld_data !== ua_ld_data || ld_addr !== ua_ld_addr) begin
                $display("FAIL: UART owns the port but the data is not its own");
                errors = errors + 1;
            end
        end else begin
            if (ld_data !== rv_ld_data || ld_addr !== rv_ld_addr) begin
                $display("FAIL: the softcore owns the port but the data is not its own");
                errors = errors + 1;
            end
        end
    end
end

initial begin
    $dumpfile("sim/tb_rom_source_arb.vcd");
    $dumpvars(0, tb_rom_source_arb);

    repeat (4) @(posedge clk);
    resetn = 1;
    @(posedge clk);

    // ---- from reset the softcore owns the port --------------------------
    chk(own_uart === 1'b0, "softcore owns the port after reset");
    chk(image_valid === 1'b0, "no image after reset");
    chk(rv_ld_busy === ld_busy, "softcore sees the real busy");
    chk(ua_ld_busy === 1'b1, "UART is masked out");

    // ---- a menu load ------------------------------------------------------
    @(posedge clk);
    rv_loading <= 1; rv_ld_addr <= 23'd10; rv_ld_data <= 8'hAA; rv_ld_wr <= 1;
    @(posedge clk);
    chk(loading === 1'b1, "loading follows the softcore");
    chk(ld_wr === 1'b1 && ld_data === 8'hAA, "softcore write reaches the port");
    @(posedge clk);
    rv_ld_wr <= 0; rv_loading <= 0; rv_image_valid <= 1; rv_rom_sz <= 8'h08;
    rv_rom_offset <= 23'd512; rv_sgx_mode <= 1'b1;
    @(posedge clk);
    @(posedge clk);
    chk(loading === 1'b0, "loading cleared");
    chk(image_valid === 1'b1 && rom_sz === 8'h08 && rom_offset === 23'd512,
        "menu image description published");
    chk(sgx_mode === 1'b1, "menu SGX mode published");

    // ---- the UART takes over ---------------------------------------------
    @(posedge clk);
    ua_loading <= 1;
    #1;
    chk(loading === 1'b1, "loading rises combinationally when the UART starts");
    chk(image_valid === 1'b0, "image invalidated as soon as the UART starts");
    chk(rv_ld_busy === 1'b1, "softcore is masked out while the UART owns");
    @(posedge clk);
    ua_ld_addr <= 23'd0; ua_ld_data <= 8'h55; ua_ld_wr <= 1;
    rv_ld_addr <= 23'd99; rv_ld_data <= 8'h77; rv_ld_wr <= 1;   // must be ignored
    @(posedge clk);
    chk(ld_wr === 1'b1 && ld_data === 8'h55 && ld_addr === 23'd0,
        "only the UART reaches the port");
    @(posedge clk);
    ua_ld_wr <= 0; rv_ld_wr <= 0;
    ua_loading <= 0; ua_image_valid <= 1; ua_rom_sz <= 8'h10; ua_rom_offset <= 23'd0;
    ua_sgx_mode <= 1'b0;
    rv_image_valid <= 1; rv_rom_sz <= 8'h08; rv_rom_offset <= 23'd512;
    @(posedge clk);
    @(posedge clk);
    chk(own_uart === 1'b1, "the UART keeps ownership after its transfer");
    chk(rom_sz === 8'h10 && rom_offset === 23'd0 && image_valid === 1'b1,
        "UART image description stays published");
    chk(sgx_mode === 1'b0, "UART defaults to PCE mode");

    // ---- and the menu can take it back -----------------------------------
    @(posedge clk);
    rv_loading <= 1;
    #1;
    chk(own_uart === 1'b0, "menu takes ownership back");
    chk(loading === 1'b1, "loading follows the menu again");
    @(posedge clk);
    rv_loading <= 0;
    @(posedge clk);
    @(posedge clk);
    chk(rom_sz === 8'h08 && rom_offset === 23'd512,
        "menu image description published again");

    if (errors == 0)
        $display("\n*** tb_rom_source_arb PASSED ***");
    else
        $display("\n*** tb_rom_source_arb FAILED with %0d error(s) ***", errors);
    $finish;
end

endmodule

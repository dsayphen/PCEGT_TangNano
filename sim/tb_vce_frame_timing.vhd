library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_vce_frame_timing is
end entity;

architecture test of tb_vce_frame_timing is
    constant clock_period : time := 10 ns;
    signal clk : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal ce_n : std_logic := '1';
    signal wr_n : std_logic := '1';
    signal data_in : std_logic_vector(7 downto 0) := x"00";
    signal control_debug : std_logic_vector(7 downto 0);
    signal vs_n : std_logic;
begin
    clk <= not clk after clock_period / 2;

    dut : entity work.huc6260
        port map (
            CLK => clk, RESET_N => reset_n,
            A => "000", CE_N => ce_n, WR_N => wr_n, RD_N => '1',
            DI => data_in, DO => open, COLNO => (others => '0'),
            CLKEN => open, HSYNC_F => open, HSYNC_R => open,
            VSYNC_F => open, VSYNC_R => open, CLKEN_FS => open,
            RVBL => '1', DCC => open, CR_DBG => control_debug, WR_DBG => open,
            GRID_EN => "00", BORDER_EN => '0', BORDER => '0', GRID => "00",
            R => open, G => open, B => open, BW => open,
            VS_N => vs_n, HS_N => open, HBL => open, VBL => open
        );

    stimulus : process
        procedure check_frame(expected_lines : natural; label_text : string) is
            variable started : time;
        begin
            wait until falling_edge(vs_n);
            started := now;
            wait until falling_edge(vs_n);
            assert now - started = expected_lines * 2730 * clock_period
                report label_text & ": incorrect frame period " & time'image(now - started)
                severity failure;
            report label_text & ": " & integer'image(expected_lines) & " lines";
        end procedure;
    begin
        check_frame(263, "Browser under reset");
        assert control_debug = x"00"
            report "Browser timing must not alter the reset control register" severity failure;

        wait until falling_edge(clk);
        reset_n <= '1';
        check_frame(262, "Game with CR bit 2 clear");

        wait until falling_edge(clk);
        ce_n <= '0';
        wr_n <= '0';
        data_in <= x"04";
        wait until falling_edge(clk);
        ce_n <= '1';
        wr_n <= '1';
        check_frame(263, "Game with CR bit 2 set");
        assert control_debug = x"04"
            report "Game control register write was not preserved" severity failure;

        wait until falling_edge(clk);
        reset_n <= '0';
        check_frame(263, "Return to browser");
        report "tb_vce_frame_timing PASSED";
        stop;
        wait;
    end process;

    watchdog : process
    begin
        wait for 100 ms;
        assert false report "tb_vce_frame_timing timeout" severity failure;
        wait;
    end process;
end architecture;
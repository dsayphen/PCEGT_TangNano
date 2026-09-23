library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_huc6270_cpu_slots is
end entity;

architecture simulation of tb_huc6270_cpu_slots is
    constant CLK_PERIOD : time := 10 ns;
    constant LINE_CYCLES : natural := 1024;

    signal clk : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal cpu_ce : std_logic := '1';
    signal cpu_a : std_logic_vector(1 downto 0) := "00";
    signal cpu_di : std_logic_vector(7 downto 0) := (others => '0');
    signal cpu_cs_n : std_logic := '1';
    signal cpu_wr_n : std_logic := '1';
    signal cpu_rd_n : std_logic := '1';
    signal busy_n : std_logic;
    signal dck_ce : std_logic := '1';
    signal hsync_f : std_logic := '0';
    signal hsync_r : std_logic := '0';
    signal vsync_f : std_logic := '0';
    signal vsync_r : std_logic := '0';
    signal ram_a : std_logic_vector(15 downto 0);
    signal ram_di : std_logic_vector(15 downto 0) := (others => '0');
    signal ram_do : std_logic_vector(15 downto 0);
    signal ram_rd : std_logic;
    signal ram_we : std_logic;
    signal hds_end_dbg : unsigned(6 downto 0);
    signal hdisp_end_dbg : unsigned(6 downto 0);
    signal hds_dbg : std_logic_vector(6 downto 0);
    signal line_pulse_count : natural := 0;

    procedure vdc_write(
        signal cpu_a : out std_logic_vector(1 downto 0);
        signal cpu_di : out std_logic_vector(7 downto 0);
        signal cpu_cs_n : out std_logic;
        signal cpu_wr_n : out std_logic;
        signal clk : in std_logic;
        constant address : std_logic_vector(1 downto 0);
        constant data : std_logic_vector(7 downto 0)
    ) is
    begin
        cpu_a <= address;
        cpu_di <= data;
        cpu_cs_n <= '0';
        cpu_wr_n <= '0';
        wait until rising_edge(clk);
        cpu_cs_n <= '1';
        cpu_wr_n <= '1';
        wait until rising_edge(clk);
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.HUC6270
        generic map (
            MAX_SPRITES => 42,
            SIM_FORCE_SPR_FETCH => true
        )
        port map (
            CLK => clk,
            RST_N => reset_n,
            CLR_MEM => '0',
            CPU_CE => cpu_ce,
            A => cpu_a,
            DI => cpu_di,
            DO => open,
            CS_N => cpu_cs_n,
            WR_N => cpu_wr_n,
            RD_N => cpu_rd_n,
            BUSY_N => busy_n,
            IRQ_N => open,
            DCK_CE => dck_ce,
            HSYNC_F => hsync_f,
            HSYNC_R => hsync_r,
            VSYNC_F => vsync_f,
            VSYNC_R => vsync_r,
            VD => open,
            BORDER => open,
            GRID => open,
            SP64 => '0',
            RAM_A => ram_a,
            RAM_DI => ram_di,
            RAM_DO => ram_do,
            RAM_RD => ram_rd,
            RAM_WE => ram_we,
            BG_EN => '1',
            SPR_EN => '1',
            IW_DBG => open,
            VM_DBG => open,
            CM_DBG => open,
            SCREEN_DBG => open,
            SOUR_DBG => open,
            DESR_DBG => open,
            LENR_DBG => open,
            SPR_X_DBG => open,
            SPR_Y_DBG => open,
            SPR_PC_DBG => open,
            SPR_CG_DBG => open,
            SPR_PAL_DBG => open,
            SPR_PRIO_DBG => open,
            SPR_CGX_DBG => open,
            SPR_CGY_DBG => open,
            SPR_HF_DBG => open,
            SPR_VF_DBG => open,
            HSW_END_POS_DBG => open,
            HDS_END_POS_DBG => hds_end_dbg,
            HDISP_END_POS_DBG => hdisp_end_dbg,
            HSW_DBG => open,
            HDS_DBG => hds_dbg,
            HDE_DBG => open,
            VDS_END_POS_DBG => open,
            VDISP_END_POS_DBG => open,
            VDE_END_POS_DBG => open
        );

    hsync_generator : process
    begin
        wait until reset_n = '1';
        loop
            for cycle_index in 1 to LINE_CYCLES loop
                wait until rising_edge(clk);
            end loop;
            hsync_f <= '1';
            wait until rising_edge(clk);
            hsync_f <= '0';
            line_pulse_count <= line_pulse_count + 1;
        end loop;
    end process;

    stimulus : process
        procedure select_register(constant register_index : natural) is
        begin
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "00",
                      std_logic_vector(to_unsigned(register_index, 8)));
        end procedure;

        procedure set_hdw(constant width : natural) is
        begin
            select_register(10);
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "10", x"03");
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "11", x"00");
            select_register(11);
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "10",
                      std_logic_vector(to_unsigned(width, 8)));
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "11", x"00");
        end procedure;

        procedure hold_vram_write(variable busy_cycles : out natural) is
        begin
            select_register(2);
            vdc_write(cpu_a, cpu_di, cpu_cs_n, cpu_wr_n, clk, "10", x"5A");
            cpu_a <= "11";
            cpu_di <= x"A5";
            cpu_cs_n <= '0';
            cpu_wr_n <= '0';
            wait until rising_edge(clk);
            wait for 0 ns;
            wait for 0 ns;
            busy_cycles := 0;
            assert busy_n = '0'
                report "CPU VRAM write did not assert BUSY_N"
                severity failure;
            while busy_n = '0' loop
                wait until rising_edge(clk);
                busy_cycles := busy_cycles + 1;
                assert busy_cycles < LINE_CYCLES * 2
                    report "CPU VRAM write did not receive a CPU slot within two lines"
                    severity failure;
            end loop;
            cpu_cs_n <= '1';
            cpu_wr_n <= '1';
            wait until rising_edge(clk);
        end procedure;

        variable busy_320 : natural := 0;
        variable busy_352 : natural := 0;
        variable current_line : natural := 0;
    begin
        wait for CLK_PERIOD * 4;
        reset_n <= '1';
        wait until line_pulse_count = 2;

        set_hdw(40);
        wait until line_pulse_count = 4;
        assert hdisp_end_dbg - hds_end_dbg = to_unsigned(41, 7)
            report "HDW=40 was not latched by the VDC"
            severity failure;
        wait until hsync_f = '1';
        for cycle_index in 1 to 8 * 47 loop
            wait until rising_edge(clk);
        end loop;
        hold_vram_write(busy_320);

        set_hdw(44);
        current_line := line_pulse_count + 2;
        wait until line_pulse_count = current_line;
        assert hdisp_end_dbg - hds_end_dbg = to_unsigned(45, 7)
            report "HDW=44 was not latched by the VDC"
            severity failure;
        wait until hsync_f = '1';
        for cycle_index in 1 to 8 * 51 loop
            wait until rising_edge(clk);
        end loop;
        hold_vram_write(busy_352);

        report "HDW=40 CPU busy cycles=" & integer'image(busy_320) &
               ", HDW=44 CPU busy cycles=" & integer'image(busy_352);
        assert busy_320 < 16 and busy_352 < 16
            report "A CPU VRAM operation remained blocked during sprite fetch"
            severity failure;
        report "tb_huc6270_cpu_slots PASSED" severity note;
        std.env.finish;
    end process;
end architecture;

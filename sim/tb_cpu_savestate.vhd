library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cpu_savestate is
end entity;

architecture test of tb_cpu_savestate is
    signal clk : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal hold_state : std_logic := '0';
    signal load_state : std_logic := '0';
    signal state_in, state_out : std_logic_vector(255 downto 0);
    signal address_bus : std_logic_vector(20 downto 0);
    signal data_in, data_out : std_logic_vector(7 downto 0);
    signal write_n, memory_cycle, speed : std_logic;
    signal cpu_done, wrapper_done, psg_done : std_logic := '0';
    signal psg_hold, psg_load : std_logic := '0';
    signal psg_in, psg_out : std_logic_vector(2148 downto 0);
    signal audio_left, audio_right : std_logic_vector(15 downto 0);
    signal video_done : std_logic := '0';
    signal video_hold, video_load : std_logic := '0';
    signal vce_in, vce_out : std_logic_vector(319 downto 0);
    signal vpc_in, vpc_out : std_logic_vector(63 downto 0);
    signal palette_req, palette_we : std_logic := '0';
    signal palette_addr, palette_data, palette_read : std_logic_vector(8 downto 0);
    signal video_colno : std_logic_vector(8 downto 0);
    signal wrapper_hold, wrapper_load : std_logic := '0';
    signal wrapper_in, wrapper_out : std_logic_vector(351 downto 0);
    signal wrapper_address : std_logic_vector(20 downto 0);
    signal wrapper_read_n, wrapper_write_n : std_logic;
begin
    clk <= not clk after 5 ns;
    with address_bus(12 downto 0) select data_in <=
        x"00" when "1111111111110",
        x"10" when "1111111111111",
        x"A9" when "1000000000000",
        x"99" when "1000000000001",
        x"F8" when "1000000000010",
        x"69" when "1000000000011",
        x"01" when "1000000000100",
        x"D8" when "1000000000101",
        x"53" when "1000000000110",
        x"01" when "1000000000111",
        x"E8" when "1000000001000",
        x"69" when "1000000001001",
        x"03" when "1000000001010",
        x"4C" when "1000000001011",
        x"00" when "1000000001100",
        x"10" when "1000000001101",
        x"EA" when others;
    dut : entity work.HUC6280_CPU
        port map (CLK => clk, RST_N => reset_n, CE => '1', RDY => '1',
                  SS_HOLD => hold_state, SS_LOAD => load_state,
                  SS_DATA => state_in, SS_Q => state_out,
                  A_OUT => address_bus, DI => data_in, DO => data_out,
                  WE_N => write_n, NMI_N => '1', IRQ1_N => '1',
                  IRQ2_N => '1', IRQT_N => '1', VDCNUM => '0',
                  MCYCLE => memory_cycle, CS => speed);
    wrapper : entity work.HUC6280
        port map (CLK => clk, RST_N => reset_n, WAIT_N => '1', RDY => '1',
                  SS_HOLD => wrapper_hold, SS_LOAD => wrapper_load,
                  SS_DATA => wrapper_in, SS_Q => wrapper_out,
                  A => wrapper_address, DI => x"EA", DO => open,
                  WR_N => wrapper_write_n, RD_N => wrapper_read_n,
                  NMI_N => '1', IRQ1_N => '1', IRQ2_N => '1',
                  CE => open, CEK_N => open, CE7_N => open, CER_N => open,
                  PRE_RD => open, PRE_WR => open, HSM => open,
                  O => open, K => x"FF", VDCNUM => '0',
                  AUD_LDATA => open, AUD_RDATA => open);
    process
        type trace_t is array(1 to 16) of std_logic_vector(255 downto 0);
        variable expected_trace : trace_t;
        variable saved_state, probe_state : std_logic_vector(255 downto 0);
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
    begin
        tick;
        reset_n <= '1';
        for cycle in 1 to 30 loop
            tick;
        end loop;
        for capture in 1 to 64 loop
            hold_state <= '1';
            tick;
            saved_state := state_out;
            for cycle in 1 to 10 loop
                tick;
                assert state_out = saved_state report "CPU changed while held" severity failure;
            end loop;
            hold_state <= '0';
            for cycle in expected_trace'range loop
                tick;
                expected_trace(cycle) := state_out;
            end loop;
            assert state_out /= saved_state report "CPU did not resume" severity failure;
            hold_state <= '1';
            state_in <= saved_state;
            load_state <= '1';
            tick;
            assert state_out = saved_state report "CPU state restore mismatch" severity failure;
            load_state <= '0';
            hold_state <= '0';
            for cycle in expected_trace'range loop
                tick;
                assert state_out = expected_trace(cycle)
                    report "CPU diverged after restore at capture " & integer'image(capture) &
                           " cycle " & integer'image(cycle) severity failure;
            end loop;
            tick;
        end loop;
        hold_state <= '1';
        load_state <= '1';
        for bit_index in 0 to 251 loop
            probe_state := (others => '0');
            probe_state(bit_index) := '1';
            state_in <= probe_state;
            tick;
            assert state_out = probe_state
                report "CPU state bit mapping mismatch at " & integer'image(bit_index) severity failure;
        end loop;
        state_in <= saved_state;
        tick;
        load_state <= '0';
        tick;
        assert state_out = saved_state report "CPU changed after restore while held" severity failure;
        report "PASS: 64 CPU captures, 1024 replay cycles and 252 state bit mappings" severity note;
        cpu_done <= '1';
        wait;
    end process;
    process
        type trace_t is array(1 to 64) of std_logic_vector(351 downto 0);
        variable expected_trace : trace_t;
        variable saved_state, probe_state : std_logic_vector(351 downto 0);
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
    begin
        wait until reset_n = '1';
        for cycle in 1 to 256 loop
            tick;
        end loop;
        wrapper_hold <= '1';
        tick;
        probe_state := wrapper_out;
        probe_state(308 downto 299) := std_logic_vector(to_unsigned(4, 10));
        probe_state(315 downto 309) := (others => '0');
        probe_state(322 downto 316) := std_logic_vector(to_unsigned(5, 7));
        probe_state(323) := '1';
        wrapper_in <= probe_state;
        wrapper_load <= '1';
        tick;
        wrapper_load <= '0';
        tick;
        saved_state := wrapper_out;
        for cycle in 1 to 64 loop
            tick;
            assert wrapper_out = saved_state report "HuC6280 changed while held" severity failure;
        end loop;
        wrapper_hold <= '0';
        for cycle in expected_trace'range loop
            tick;
            expected_trace(cycle) := wrapper_out;
        end loop;
        assert wrapper_out(308 downto 299) /= saved_state(308 downto 299)
            report "Timer did not resume" severity failure;
        assert wrapper_out(325) = '1'
            report "Timer interrupt did not fire" severity failure;
        wrapper_hold <= '1';
        wrapper_in <= saved_state;
        wrapper_load <= '1';
        tick;
        assert wrapper_out = saved_state report "HuC6280 restore mismatch" severity failure;
        wrapper_load <= '0';
        wrapper_hold <= '0';
        for cycle in expected_trace'range loop
            tick;
            assert wrapper_out = expected_trace(cycle)
                report "HuC6280 timer/bus replay diverged" severity failure;
        end loop;
        wrapper_hold <= '1';
        wrapper_load <= '1';
        for bit_index in 0 to 325 loop
            if bit_index < 252 or bit_index >= 256 then
                probe_state := (others => '0');
                probe_state(bit_index) := '1';
                wrapper_in <= probe_state;
                tick;
                assert wrapper_out = probe_state
                    report "HuC6280 bit mapping mismatch at " & integer'image(bit_index) severity failure;
            end if;
        end loop;
        wrapper_in <= saved_state;
        tick;
        wrapper_load <= '0';
        report "PASS: HuC6280 timer/bus freeze, 64 replay cycles and 322 state bit mappings" severity note;
        wrapper_done <= '1';
        wait;
    end process;
    audio_dut : entity work.psg
        generic map (O_WIDTH => 16, VOLTAB_FILE => "voltab_small.mif")
        port map (CLK => clk, CLKEN => '1', RESET_N => reset_n,
                  SS_HOLD => psg_hold, SS_LOAD => psg_load,
                  SS_DATA => psg_in, SS_Q => psg_out,
                  DI => x"00", A => "0000", WE => '0', DAC_LATCH => '1',
                  LDATA => audio_left, RDATA => audio_right);
    process
        type trace_t is array(1 to 128) of std_logic_vector(2148 downto 0);
        variable expected_trace : trace_t;
        variable saved_state, initial_state : std_logic_vector(2148 downto 0);
        variable heard_audio : boolean := false;
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
    begin
        wait until reset_n = '1';
        psg_hold <= '1';
        psg_load <= '1';
        initial_state := (others => '0');
        initial_state(1930 downto 1923) := x"FF";
        for channel in 0 to 5 loop
            initial_state(channel*320+11 downto channel*320) := std_logic_vector(to_unsigned(7+channel, 12));
            initial_state(channel*320+13) := '1';
            initial_state(channel*320+26 downto channel*320+14) := (others => '1');
            initial_state(channel*320+53) := '1';
            for sample_index in 0 to 31 loop
                initial_state(channel*320+138+sample_index*5 downto channel*320+134+sample_index*5) :=
                    std_logic_vector(to_unsigned((sample_index+channel) mod 32, 5));
            end loop;
        end loop;
        initial_state(4*320+32) := '1';
        initial_state(5*320+32) := '1';
        initial_state(320+111) := '1';
        initial_state(320+110 downto 320+103) := x"03";
        psg_in <= initial_state;
        tick;
        assert psg_out = initial_state
            report "PSG initial restore mismatch: " & to_hstring(psg_out xor initial_state) severity failure;
        psg_load <= '0';
        psg_hold <= '0';
        for cycle in 1 to 256 loop
            tick;
        end loop;
        for capture in 1 to 32 loop
            psg_hold <= '1';
            tick;
            saved_state := psg_out;
            for cycle in 1 to 8 loop
                tick;
                assert psg_out = saved_state report "PSG changed while held" severity failure;
            end loop;
            psg_hold <= '0';
            for cycle in expected_trace'range loop
                tick;
                expected_trace(cycle) := psg_out;
                if audio_left /= x"0000" or audio_right /= x"0000" then
                    heard_audio := true;
                end if;
            end loop;
            psg_hold <= '1';
            psg_load <= '1';
            psg_in <= saved_state;
            tick;
            assert psg_out = saved_state report "PSG restore mismatch" severity failure;
            psg_load <= '0';
            psg_hold <= '0';
            for cycle in expected_trace'range loop
                tick;
                assert psg_out = expected_trace(cycle)
                    report "PSG/audio replay diverged at capture " & integer'image(capture) &
                           " cycle " & integer'image(cycle) severity failure;
            end loop;
            tick;
        end loop;
        assert heard_audio report "PSG test produced no audio" severity failure;
        report "PASS: 32 PSG captures and 4096 deterministic waveform/noise/LFO/audio replay cycles" severity note;
        psg_done <= '1';
        wait;
    end process;
    video_colno <= vce_out(104 downto 96);
    vce_dut : entity work.huc6260
        port map (CLK => clk, RESET_N => reset_n,
                  SS_HOLD => video_hold, SS_LOAD => video_load,
                  SS_DATA => vce_in, SS_Q => vce_out,
                  SS_MEM_REQ => palette_req, SS_MEM_WE => palette_we,
                  SS_MEM_ADDR => palette_addr, SS_MEM_DI => palette_data,
                  SS_MEM_Q => palette_read,
                  A => "000", CE_N => '1', WR_N => '1', RD_N => '1',
                  DI => x"00", DO => open, COLNO => video_colno,
                  CLKEN => open, HSYNC_F => open, HSYNC_R => open,
                  VSYNC_F => open, VSYNC_R => open, CLKEN_FS => open,
                  RVBL => '0', DCC => open, CR_DBG => open, WR_DBG => open,
                  GRID_EN => "00", BORDER_EN => '0', BORDER => '0', GRID => "00",
                  R => open, G => open, B => open, BW => open,
                  VS_N => open, HS_N => open, HBL => open, VBL => open);
    vpc_dut : entity work.huc6202
        port map (CLK => clk, CLKEN => vce_out(130), RESET_N => reset_n,
                  SS_HOLD => video_hold, SS_LOAD => video_load,
                  SS_DATA => vpc_in, SS_Q => vpc_out,
                  A => "000", WR_N => '1', DI => x"00", DO => open,
                  HS_F => vce_out(160), VDC0_IN => video_colno,
                  VDC1_IN => not video_colno, VDC_OUT => open,
                  SGX => '1', VDCNUM => open);
    process
        type trace_t is array(1 to 128) of std_logic_vector(383 downto 0);
        variable expected_trace : trace_t;
        variable saved_state : std_logic_vector(383 downto 0);
        variable initial_vce : std_logic_vector(319 downto 0);
        variable initial_vpc : std_logic_vector(63 downto 0);
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
    begin
        wait until reset_n = '1';
        video_hold <= '1';
        video_load <= '1';
        initial_vce := (others => '0');
        initial_vce(107 downto 96) := std_logic_vector(to_unsigned(2170, 12));
        initial_vce(117 downto 108) := std_logic_vector(to_unsigned(262, 10));
        initial_vce(126 downto 118) := std_logic_vector(to_unsigned(263, 9));
        initial_vpc := (others => '0');
        initial_vpc(15 downto 0) := x"1111";
        vce_in <= initial_vce;
        vpc_in <= initial_vpc;
        tick;
        assert vce_out = initial_vce report "VCE initial restore mismatch" severity failure;
        assert vpc_out = initial_vpc report "VPC initial restore mismatch" severity failure;
        video_load <= '0';
        palette_req <= '1';
        palette_we <= '1';
        for entry_index in 0 to 511 loop
            palette_addr <= std_logic_vector(to_unsigned(entry_index, 9));
            palette_data <= std_logic_vector(to_unsigned((entry_index*3) mod 512, 9));
            tick;
        end loop;
        palette_we <= '0';
        for entry_index in 0 to 511 loop
            palette_addr <= std_logic_vector(to_unsigned(entry_index, 9));
            tick;
            assert palette_read = std_logic_vector(to_unsigned((entry_index*3) mod 512, 9))
                report "Palette write/read mismatch" severity failure;
        end loop;
        palette_req <= '0';
        video_hold <= '0';
        for cycle in 1 to 512 loop
            tick;
        end loop;
        for capture in 1 to 8 loop
            video_hold <= '1';
            tick;
            saved_state := vpc_out & vce_out;
            palette_req <= '1';
            for entry_index in 0 to 511 loop
                palette_addr <= std_logic_vector(to_unsigned(entry_index, 9));
                tick;
                assert palette_read = std_logic_vector(to_unsigned((entry_index*3) mod 512, 9))
                    report "Palette capture mismatch" severity failure;
                assert (vpc_out & vce_out) = saved_state
                    report "Video state changed during palette capture" severity failure;
            end loop;
            palette_req <= '0';
            video_hold <= '0';
            for cycle in expected_trace'range loop
                tick;
                expected_trace(cycle) := vpc_out & vce_out;
            end loop;
            video_hold <= '1';
            video_load <= '1';
            vce_in <= saved_state(319 downto 0);
            vpc_in <= saved_state(383 downto 320);
            tick;
            assert (vpc_out & vce_out) = saved_state report "Video restore mismatch" severity failure;
            video_load <= '0';
            video_hold <= '0';
            for cycle in expected_trace'range loop
                tick;
                assert (vpc_out & vce_out) = expected_trace(cycle)
                    report "VCE/VPC replay diverged at capture " & integer'image(capture) &
                           " cycle " & integer'image(cycle) severity failure;
            end loop;
            tick;
        end loop;
        report "PASS: palette access, 8 VCE/VPC captures and 1024 deterministic video replay cycles" severity note;
        video_done <= '1';
        wait;
    end process;
    process
    begin
        wait until cpu_done = '1' and wrapper_done = '1' and psg_done = '1' and video_done = '1';
        std.env.stop;
        wait;
    end process;
    process
    begin
        wait for 1 ms;
        assert false report "CPU savestate test timed out" severity failure;
    end process;
end architecture;
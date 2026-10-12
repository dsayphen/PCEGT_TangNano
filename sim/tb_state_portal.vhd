library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_state_portal is end entity;
architecture test of tb_state_portal is
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal hold_state, write_state : std_logic := '0';
    signal state_addr : std_logic_vector(19 downto 0) := (others => '0');
    signal state_data, state_q : std_logic_vector(31 downto 0) := (others => '0');
    signal audio_l, audio_r : std_logic_vector(19 downto 0);
    signal video_r, video_g, video_b : std_logic_vector(2 downto 0);
    signal video_ce, video_hs, video_vs, video_hbl, video_vbl : std_logic;
    signal rom_address : std_logic_vector(21 downto 0);
    signal vram0_address, vram1_address : std_logic_vector(15 downto 0);
begin
    clk <= not clk after 5 ns;
    dut : entity work.pce_core
        generic map (SGX_SUPPORT => 1, CD_SUPPORT => 0, AC_SUPPORT => 0, CHEAT_SUPPORT => 0)
        port map (clk => clk, reset => reset, cold_reset => reset, cpu_pause => '0',
                  ss_hold => hold_state, ss_write => write_state,
                  ss_addr => state_addr, ss_data => state_data, ss_q => state_q,
                  cheat_apply => '0', cheat_reset => '0', cheat_code => (others => '0'),
                  rom_rdy => '1', rom_do => x"EA", rom_sz => x"08", rom_a => rom_address,
                  sgx_mode => '1', cd_enable => '0', cd_audio_hold => '0', rom_pop => '0',
                  brm_host_addr => (others => '0'), brm_host_data => (others => '0'),
                  brm_host_we => '0', brm_host_access => '0',
                  vram0_di => x"1234", vram1_di => x"5678",
                  vram0_a => vram0_address, vram1_a => vram1_address, joy_in => x"F",
                  aud_l => audio_l, aud_r => audio_r, vid_ce => video_ce,
                  vid_r => video_r, vid_g => video_g, vid_b => video_b,
                  vid_hs => video_hs, vid_vs => video_vs, vid_hbl => video_hbl, vid_vbl => video_vbl,
                  cd_stat => (others => '0'), cd_stat_get => '0', cd_dout_req => '0',
                  cd_data => (others => '0'), cd_wr => '0', cd_dm => '0',
                  adram_do => (others => '0'), ext_ram_di => (others => '0'), ext_ram_rdy => '1');
    process
        type counts_t is array(0 to 15) of integer;
        constant counts : counts_t := (11, 68, 10, 2, 256, 256, 32768, 512, 256, 512, 512, 256, 512, 512, 3, 2048);
        type image_t is array(0 to 38493) of std_logic_vector(31 downto 0);
        variable image : image_t;
        type trace_t is array(1 to 128) of std_logic_vector(107 downto 0);
        variable trace : trace_t;
        variable image_index : integer;
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
        procedure address(bank, word_index : integer) is
        begin
            state_addr <= std_logic_vector(to_unsigned(bank*65536+word_index, 20));
            tick; tick;
        end procedure;
        procedure write_word(value : std_logic_vector(31 downto 0)) is
        begin
            state_data <= value; write_state <= '1'; tick;
            write_state <= '0'; tick;
        end procedure;
    begin
        for cycle in 1 to 4 loop tick; end loop;
        reset <= '0'; hold_state <= '1'; tick; tick;
        for bank in 0 to 5 loop
            for word_index in 0 to counts(bank)-1 loop
                address(bank, word_index); write_word(x"00000000");
            end loop;
        end loop;
        address(14, 0); write_word(x"00800000");
        address(14, 1); write_word(x"00000000");
        address(14, 2); write_word(x"00000000");
        for bank in 6 to 15 loop
            if bank /= 14 then
                for word_index in 0 to 255 loop
                    address(bank, word_index);
                    write_word(std_logic_vector(to_unsigned((word_index+bank) mod 256, 32)));
                end loop;
            end if;
        end loop;
        hold_state <= '0';
        for cycle in 1 to 256 loop tick; end loop;
        hold_state <= '1'; tick; tick;
        image_index := 0;
        for bank in 0 to 15 loop
            for word_index in 0 to counts(bank)-1 loop
                address(bank, word_index);
                image(image_index) := state_q;
                image_index := image_index+1;
            end loop;
        end loop;
        assert image_index = image'length report "Portal image length mismatch" severity failure;
        hold_state <= '0';
        for cycle in trace'range loop
            tick;
            trace(cycle) := audio_l & audio_r & video_r & video_g & video_b &
                video_ce & video_hs & video_vs & video_hbl & video_vbl &
                rom_address & vram0_address & vram1_address;
        end loop;
        hold_state <= '1'; tick; tick;
        image_index := 0;
        for bank in 0 to 15 loop
            for word_index in 0 to counts(bank)-1 loop
                address(bank, word_index); write_word(image(image_index));
                image_index := image_index+1;
            end loop;
        end loop;
        hold_state <= '0';
        for cycle in trace'range loop
            tick;
            assert (audio_l & audio_r & video_r & video_g & video_b &
                    video_ce & video_hs & video_vs & video_hbl & video_vbl &
                    rom_address & vram0_address & vram1_address) = trace(cycle)
                report "Whole-core portal replay diverged at cycle " & integer'image(cycle) severity failure;
        end loop;
        report "PASS: 38494-word portal capture/restore and 128 whole-core replay cycles" severity note;
        std.env.stop;
        wait;
    end process;
    process begin wait for 10 ms; assert false report "Portal test timeout" severity failure; end process;
end architecture;
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_vdc_savestate is end entity;
architecture test of tb_vdc_savestate is
    signal clk : std_logic := '0';
    signal reset_n : std_logic := '0';
    signal hold_state, load_state, memory_req, memory_we : std_logic := '0';
    signal state_in, state_out : std_logic_vector(8191 downto 0);
    signal memory_select : std_logic_vector(1 downto 0);
    signal memory_addr : std_logic_vector(8 downto 0);
    signal memory_di, memory_q : std_logic_vector(15 downto 0);
    signal vram_addr, vram_data : std_logic_vector(15 downto 0);
    signal vram_read, vram_write, irq_n, busy_n, border : std_logic;
    signal pixels : std_logic_vector(8 downto 0);
    signal grid : std_logic_vector(1 downto 0);
begin
    clk <= not clk after 5 ns;
    dut : entity work.HUC6270 generic map (MAX_SPRITES => 32)
        port map (CLK => clk, RST_N => reset_n, CLR_MEM => '0',
                  SS_HOLD => hold_state, SS_LOAD => load_state,
                  SS_DATA => state_in, SS_Q => state_out,
                  SS_MEM_REQ => memory_req, SS_MEM_WE => memory_we,
                  SS_MEM_SELECT => memory_select, SS_MEM_ADDR => memory_addr,
                  SS_MEM_DI => memory_di, SS_MEM_Q => memory_q,
                  CPU_CE => '0', A => "00", DI => x"00", DO => open,
                  CS_N => '1', WR_N => '1', RD_N => '1', BUSY_N => busy_n, IRQ_N => irq_n,
                  DCK_CE => '1', HSYNC_F => '0', HSYNC_R => '0', VSYNC_F => '0', VSYNC_R => '0',
                  VD => pixels, BORDER => border, GRID => grid,
                  RAM_A => vram_addr, RAM_DI => x"1234", RAM_DO => vram_data,
                  RAM_RD => vram_read, RAM_WE => vram_write, BG_EN => '1', SPR_EN => '1',
                  IW_DBG => open, VM_DBG => open, CM_DBG => open, SCREEN_DBG => open,
                  SOUR_DBG => open, DESR_DBG => open, LENR_DBG => open,
                  SPR_X_DBG => open, SPR_Y_DBG => open, SPR_PC_DBG => open,
                  SPR_CG_DBG => open, SPR_PAL_DBG => open, SPR_PRIO_DBG => open,
                  SPR_CGX_DBG => open, SPR_CGY_DBG => open, SPR_HF_DBG => open, SPR_VF_DBG => open,
                  HSW_END_POS_DBG => open, HDS_END_POS_DBG => open, HDISP_END_POS_DBG => open,
                  HSW_DBG => open, HDS_DBG => open, HDE_DBG => open,
                  VSW_DBG => open, VDS_DBG => open, VDW_DBG => open, VCR_DBG => open,
                  VDS_END_POS_DBG => open, VDISP_END_POS_DBG => open, VDE_END_POS_DBG => open);
    process
        type trace_t is array(1 to 128) of std_logic_vector(8239 downto 0);
        variable trace : trace_t;
        variable saved_state, initial_state : std_logic_vector(8191 downto 0);
        type memory_image_t is array(0 to 1279) of std_logic_vector(15 downto 0);
        variable saved_memory : memory_image_t;
        variable memory_index, last_address : integer;
        variable expected_value : std_logic_vector(15 downto 0);
        procedure tick is
        begin
            wait until rising_edge(clk);
            wait for 1 ns;
        end procedure;
    begin
        tick;
        reset_n <= '1'; hold_state <= '1'; load_state <= '1';
        initial_state := (others => '0');
        state_in <= initial_state;
        tick;
        assert state_out = initial_state report "VDC initial restore mismatch" severity failure;
        load_state <= '0'; memory_req <= '1'; memory_we <= '1';
        for bank in 0 to 2 loop
            memory_select <= std_logic_vector(to_unsigned(bank, 2));
            for address_index in 0 to 255 loop
                memory_addr <= std_logic_vector(to_unsigned(address_index, 9));
                memory_di <= std_logic_vector(to_unsigned(address_index + bank*256, 16));
                tick;
            end loop;
        end loop;
        memory_we <= '0';
        for bank in 0 to 2 loop
            memory_select <= std_logic_vector(to_unsigned(bank, 2));
            for address_index in 0 to 255 loop
                memory_addr <= std_logic_vector(to_unsigned(address_index, 9));
                tick;
                expected_value := std_logic_vector(to_unsigned(address_index + bank*256, 16));
                assert memory_q = expected_value report "VDC RAM host access mismatch" severity failure;
                assert state_out = initial_state report "VDC changed during host access" severity failure;
            end loop;
        end loop;
        memory_req <= '0'; hold_state <= '0';
        for cycle in 1 to 16 loop tick; end loop;
        for capture in 1 to 8 loop
            hold_state <= '1'; tick; saved_state := state_out;
            memory_req <= '1'; memory_we <= '0'; memory_index := 0;
            for bank in 0 to 2 loop
                memory_select <= std_logic_vector(to_unsigned(bank, 2));
                if bank = 0 then last_address := 255; else last_address := 511; end if;
                for address_index in 0 to last_address loop
                    memory_addr <= std_logic_vector(to_unsigned(address_index, 9));
                    tick;
                    saved_memory(memory_index) := memory_q;
                    memory_index := memory_index + 1;
                end loop;
            end loop;
            memory_req <= '0';
            for cycle in 1 to 8 loop
                tick;
                assert state_out = saved_state report "VDC changed while held" severity failure;
            end loop;
            hold_state <= '0';
            for cycle in trace'range loop
                tick;
                trace(cycle) := state_out & vram_addr & vram_data & pixels & grid & border & irq_n & busy_n & vram_read & vram_write;
            end loop;
            hold_state <= '1'; memory_req <= '1'; memory_we <= '1'; memory_index := 0;
            for bank in 0 to 2 loop
                memory_select <= std_logic_vector(to_unsigned(bank, 2));
                if bank = 0 then last_address := 255; else last_address := 511; end if;
                for address_index in 0 to last_address loop
                    memory_addr <= std_logic_vector(to_unsigned(address_index, 9));
                    memory_di <= saved_memory(memory_index);
                    memory_index := memory_index + 1;
                    tick;
                end loop;
            end loop;
            memory_req <= '0'; memory_we <= '0'; load_state <= '1'; state_in <= saved_state;
            tick;
            assert state_out = saved_state report "VDC restore mismatch" severity failure;
            load_state <= '0'; hold_state <= '0';
            for cycle in trace'range loop
                tick;
                for bit_index in 0 to 8191 loop
                    assert state_out(bit_index) = trace(cycle)(bit_index+48)
                        report "VDC state divergence at capture " & integer'image(capture) &
                               " cycle " & integer'image(cycle) & " bit " & integer'image(bit_index)
                        severity failure;
                end loop;
                assert (state_out & vram_addr & vram_data & pixels & grid & border & irq_n & busy_n & vram_read & vram_write) = trace(cycle)
                    report "VDC replay diverged" severity failure;
            end loop;
            tick;
        end loop;
        report "PASS: VDC SAT/line RAM access, 8 captures and 1024 replay cycles" severity note;
        std.env.stop;
        wait;
    end process;
    process begin wait for 1 ms; assert false report "VDC savestate timeout" severity failure; end process;
end architecture;
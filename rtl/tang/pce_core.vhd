--------------------------------------------------------------------------------
-- PCE/CD/SuperGrafx wrapper around pce_top (extram variant) for Tang Nano 20K.
--
-- Purpose:
--   * enable the SuperGrafx second VDC, CD-ROM unit and Game Genie
--   * use internal block RAM for the 8 KiB work RAM and backup RAM
--   * expose both VDC video RAM ports to the interleaved SDRAM controller
--   * expose a small, all-lowercase port list to the Verilog top level
--
-- HuCard/CD-ROM data and both VDC VRAMs use the on-package SDRAM.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity pce_core is
    generic (
        -- 0 = HuCard standard (un seul VDC, fonctionnel sur ce device)
		-- 1 = SuperGrafx (second VDC + VRAM doublée)
		SGX_SUPPORT : integer := 1;
		CD_SUPPORT  : integer := 1;
		AC_SUPPORT  : integer := 1;
		INTERNAL_VRAM : integer := 0
	);

	port (
		clk        : in  std_logic;
		reset      : in  std_logic;
		cold_reset : in  std_logic;
		cpu_pause  : in  std_logic;
		cheat_apply : in std_logic;
		cheat_reset : in std_logic;
		cheat_code : in std_logic_vector(128 downto 0);

		-- HuCard ROM (external, SDRAM)
		rom_rd     : out std_logic;
		rom_rdy    : in  std_logic;
		rom_a      : out std_logic_vector(21 downto 0);
		rom_do     : in  std_logic_vector(7 downto 0);
		rom_sz     : in  std_logic_vector(7 downto 0);
		sgx_mode   : in  std_logic;
		cd_enable  : in  std_logic;
		cd_audio_hold : in std_logic;
		rom_pop    : in  std_logic;
		brm_host_addr : in  std_logic_vector(10 downto 0);
		brm_host_data : in  std_logic_vector(7 downto 0);
		brm_host_we   : in  std_logic;
		brm_host_access : in std_logic;
		brm_host_q    : out std_logic_vector(7 downto 0);

		-- VDC0 video RAM (external SDRAM)
		vram0_a    : out std_logic_vector(15 downto 0);
		vram0_do   : out std_logic_vector(15 downto 0);
		vram0_di   : in  std_logic_vector(15 downto 0);
		vram0_rd   : out std_logic;
		vram0_we   : out std_logic;

		-- VDC1 video RAM (external SDRAM, SuperGrafx)
		vram1_a    : out std_logic_vector(15 downto 0);
		vram1_do   : out std_logic_vector(15 downto 0);
		vram1_di   : in  std_logic_vector(15 downto 0);
		vram1_rd   : out std_logic;
		vram1_we   : out std_logic;

		-- pad
		joy_out    : out std_logic_vector(1 downto 0);
		joy_in     : in  std_logic_vector(3 downto 0);

		-- audio (signed)
		aud_l      : out std_logic_vector(19 downto 0);
		aud_r      : out std_logic_vector(19 downto 0);

		-- video
		vid_ce     : out std_logic;
		vid_r      : out std_logic_vector(2 downto 0);
		vid_g      : out std_logic_vector(2 downto 0);
		vid_b      : out std_logic_vector(2 downto 0);
		vid_hs     : out std_logic;
		vid_vs     : out std_logic;
		vid_hbl    : out std_logic;
		vid_vbl    : out std_logic;
		vid_dcc    : out std_logic_vector(1 downto 0);
		-- VDC0 active display width in 8-pixel characters, debug/diagnosis only
		vid_hdw_dbg : out std_logic_vector(6 downto 0);
		vid_hds_dbg : out std_logic_vector(6 downto 0);
		vid_hsw_dbg : out std_logic_vector(4 downto 0);
		vid_hde_dbg : out std_logic_vector(6 downto 0);
		vid_vsw_dbg : out std_logic_vector(4 downto 0);
		vid_vds_dbg : out std_logic_vector(7 downto 0);
		vid_vdw_dbg : out std_logic_vector(8 downto 0);
		vid_vcr_dbg : out std_logic_vector(7 downto 0);
		vid_vce_cr_dbg : out std_logic_vector(7 downto 0);
		vid_vce_wr_dbg : out std_logic_vector(15 downto 0);

		-- CD host bridge, serviced by the firmware through iosys
		cd_stat       : in  std_logic_vector(15 downto 0);
		cd_stat_get   : in  std_logic;
		cd_comm       : out std_logic_vector(95 downto 0);
		cd_comm_send  : out std_logic;
		cd_dout_req   : in  std_logic;
		cd_dout       : out std_logic_vector(79 downto 0);
		cd_dout_send  : out std_logic;
		cd_reset      : out std_logic;
		cd_data       : in  std_logic_vector(7 downto 0);
		cd_wr         : in  std_logic;
		cd_data_end   : out std_logic;
		cd_dm         : in  std_logic;
		cd_fifo_halffull : out std_logic;
		cd_phase_dbg     : out std_logic_vector(7 downto 0);
		cdda_usedw_dbg   : out std_logic_vector(12 downto 0);
		adpcm_dbg        : out std_logic_vector(7 downto 0);
		adram_a          : out std_logic_vector(16 downto 0);
		adram_di         : out std_logic_vector(3 downto 0);
		adram_do         : in  std_logic_vector(3 downto 0);
		adram_we         : out std_logic;
		adram_rd         : out std_logic;
		adram_clken      : out std_logic;

		-- CD-ROM^2 backup/scratch RAM (256 KiB), external SDRAM
		ext_ram_a    : out std_logic_vector(21 downto 0);
		ext_ram_do   : out std_logic_vector(7 downto 0);
		ext_ram_di   : in  std_logic_vector(7 downto 0);
		ext_ram_ce   : out std_logic;
		ext_ram_rd   : out std_logic;
		ext_ram_wr   : out std_logic;
		ext_ram_rdy  : in  std_logic
	);
end pce_core;

architecture rtl of pce_core is

    signal sgx_i    : std_logic;
	signal vram0_a_core : std_logic_vector(15 downto 0);
	signal vram0_do_core : std_logic_vector(15 downto 0);
	signal vram0_di_core : std_logic_vector(15 downto 0);
	signal vram0_rd_core : std_logic;
	signal vram0_we_core : std_logic;
	signal vram0_q : std_logic_vector(15 downto 0);
	signal vram0_hi : std_logic;

	signal ff_byte   : std_logic_vector(7 downto 0) := x"FF";
	signal zero_byte : std_logic_vector(7 downto 0) := x"00";

	signal brm_a_i  : std_logic_vector(10 downto 0);
	signal brm_di_i : std_logic_vector(7 downto 0);
	signal brm_do_i : std_logic_vector(7 downto 0);
	signal brm_we_i : std_logic;
	signal brm_ram_a : std_logic_vector(10 downto 0);
	signal brm_ram_di : std_logic_vector(7 downto 0);
	signal brm_ram_we : std_logic;
	signal brm_ram_q : std_logic_vector(7 downto 0);

	signal psg_l : signed(19 downto 0);
	signal psg_r : signed(19 downto 0);
	signal aud_mix_l : signed(21 downto 0);
	signal aud_mix_r : signed(21 downto 0);

	-- Arcade Card / Game Genie outputs not used by this build
	signal cdda_l : signed(19 downto 0);
	signal cdda_r : signed(19 downto 0);
	signal adpcm_nc  : signed(15 downto 0);

	function saturate_audio(value : signed(21 downto 0)) return signed is
		variable result : signed(19 downto 0);
	begin
		if value(21 downto 19) = "000" or value(21 downto 19) = "111" then
			result := value(19 downto 0);
		elsif value(21) = '0' then
			result := '0' & (18 downto 0 => '1');
		else
			result := '1' & (18 downto 0 => '0');
		end if;
		return result;
	end function;

begin

    sgx_i <= sgx_mode when SGX_SUPPORT /= 0 else '0';

	gen_internal_vram: if (INTERNAL_VRAM /= 0) generate begin
		VRAM0_RAM : entity work.dpram
		generic map (
			addr_width => 15,
			data_width => 16
		)
		port map (
			clock     => clk,
			address_a => vram0_a_core(14 downto 0),
			data_a    => vram0_do_core,
			wren_a    => vram0_we_core,
			q_a       => vram0_q
		);

		process (clk)
		begin
			if rising_edge(clk) then
				vram0_hi <= vram0_a_core(15);
			end if;
		end process;

		vram0_di_core <= (others => '0') when vram0_hi = '1' else vram0_q;
		vram0_a  <= (others => '0');
		vram0_do <= (others => '0');
		vram0_rd <= '0';
		vram0_we <= '0';
	end generate;

	gen_external_vram: if (INTERNAL_VRAM = 0) generate begin
		vram0_a       <= vram0_a_core;
		vram0_do      <= vram0_do_core;
		vram0_rd      <= vram0_rd_core;
		vram0_we      <= vram0_we_core;
		vram0_di_core <= vram0_di;
	end generate;

	CORE : entity work.pce_top
	generic map (
		SGX_SUPPORT      => SGX_SUPPORT,
		CHEAT_SUPPORT    => 1,
		PSG_O_WIDTH      => 20,
		MAX_SPRITES      => 16,
		USE_INTERNAL_RAM => 1,
		CD_SUPPORT       => CD_SUPPORT,
		AC_SUPPORT       => AC_SUPPORT
	)
	port map (
		RESET       => reset,
		COLD_RESET  => cold_reset,
		CLK         => clk,

		ROM_RD      => rom_rd,
		ROM_RDY     => rom_rdy,
		ROM_A       => rom_a,
		ROM_DO      => rom_do,
		ROM_SZ      => rom_sz,
		ROM_POP     => rom_pop,
		ROM_CLKEN   => open,

		BRM_A       => brm_a_i,
		BRM_DI      => brm_di_i,
		BRM_DO      => brm_do_i,
		BRM_WE      => brm_we_i,

		VRAM0_A     => vram0_a_core,
		VRAM0_DO    => vram0_do_core,
		VRAM0_RD    => vram0_rd_core,
		VRAM0_WE    => vram0_we_core,
		VRAM0_DI    => vram0_di_core,

        VRAM1_A     => vram1_a,
        VRAM1_DO    => vram1_do,
        VRAM1_RD    => vram1_rd,
        VRAM1_WE    => vram1_we,
        VRAM1_DI    => vram1_di,

		GG_EN       => not cheat_apply,
		GG_CODE     => cheat_code,
		GG_RESET    => cheat_reset,
		GG_AVAIL    => open,

		SP64        => '0',
		SGX         => sgx_i,

		JOY_OUT     => joy_out,
		JOY_IN      => joy_in,

		CD_EN       => cd_enable,
		CD_AUDIO_HOLD => cd_audio_hold,
		EXT_RAM_A   => ext_ram_a,
		EXT_RAM_DO  => ext_ram_do,
		EXT_RAM_DI  => ext_ram_di,
		EXT_RAM_CE  => ext_ram_ce,
		EXT_RAM_RD  => ext_ram_rd,
		EXT_RAM_WR  => ext_ram_wr,
		EXT_RAM_RDY => ext_ram_rdy,
		AC_EN       => cd_enable,

		ADRAM_A     => adram_a,
		ADRAM_DI    => adram_di,
		ADRAM_DO    => adram_do,
		ADRAM_WE    => adram_we,
		ADRAM_RD    => adram_rd,
		ADRAM_CLKEN => adram_clken,

		CD_STAT     => cd_stat(7 downto 0),
		CD_MSG      => cd_stat(15 downto 8),
		CD_STAT_GET => cd_stat_get,

		CD_COMM     => cd_comm,
		CD_COMM_SEND=> cd_comm_send,

		CD_DOUT_REQ => cd_dout_req,
		CD_DOUT     => cd_dout,
		CD_DOUT_SEND=> cd_dout_send,

		CD_REGION   => '0',
		CD_RESET    => cd_reset,

		CD_DATA     => cd_data,
		CD_WR       => cd_wr,
		CD_DATA_END => cd_data_end,
		CD_DM       => cd_dm,
		CD_FIFO_HALFFULL => cd_fifo_halffull,

		CDDA_SL     => cdda_l,
		CDDA_SR     => cdda_r,
		ADPCM_S     => adpcm_nc,
		PSG_SL      => psg_l,
		PSG_SR      => psg_r,

		BG_EN       => '1',
		SPR_EN      => '1',
		GRID_EN     => "00",
		CPU_PAUSE_EN=> cpu_pause,

		BORDER_EN   => '0',
		ReducedVBL  => '1',
		VIDEO_DCC   => vid_dcc,
		VIDEO_R     => vid_r,
		VIDEO_G     => vid_g,
		VIDEO_B     => vid_b,
		VIDEO_BW    => open,
		VIDEO_CE    => vid_ce,
		VIDEO_CE_FS => open,
		VIDEO_VS    => vid_vs,
		VIDEO_HS    => vid_hs,
		VIDEO_HBL   => vid_hbl,
		VIDEO_VBL   => vid_vbl,
		VIDEO_HDW_DBG => vid_hdw_dbg,
		VIDEO_HDS_DBG => vid_hds_dbg,
		VIDEO_HSW_DBG => vid_hsw_dbg,
		VIDEO_HDE_DBG => vid_hde_dbg,
		VIDEO_VSW_DBG => vid_vsw_dbg,
		VIDEO_VDS_DBG => vid_vds_dbg,
		VIDEO_VDW_DBG => vid_vdw_dbg,
		VIDEO_VCR_DBG => vid_vcr_dbg,
		VIDEO_VCE_CR_DBG => vid_vce_cr_dbg,
		VIDEO_VCE_WR_DBG => vid_vce_wr_dbg,
		CD_PHASE_DBG  => cd_phase_dbg,
		CDDA_USEDW_DBG => cdda_usedw_dbg,
		ADPCM_DBG => adpcm_dbg
	);

	aud_mix_l <= resize(psg_l, aud_mix_l'length) +
		      resize(cdda_l, aud_mix_l'length) +
		      shift_left(resize(adpcm_nc, aud_mix_l'length), 4);
	aud_mix_r <= resize(psg_r, aud_mix_r'length) +
		      resize(cdda_r, aud_mix_r'length) +
		      shift_left(resize(adpcm_nc, aud_mix_r'length), 4);
	aud_l <= std_logic_vector(saturate_audio(aud_mix_l));
	aud_r <= std_logic_vector(saturate_audio(aud_mix_r));

	-- 2 KiB battery-backed save RAM used by CD-ROM^2 games; a real block RAM
	-- (not a hardwired constant) so BIOS/game write-then-verify checks succeed
	BRM_RAM : entity work.dpram
	generic map (
		addr_width => 11,
		data_width => 8
	)
	port map (
		clock     => clk,
		address_a => brm_ram_a,
		data_a    => brm_ram_di,
		wren_a    => brm_ram_we,
		q_a       => brm_ram_q
	);

	brm_ram_a  <= brm_host_addr when brm_host_access = '1' else brm_a_i;
	brm_ram_di <= brm_host_data when brm_host_access = '1' else brm_di_i;
	brm_ram_we <= brm_host_we when brm_host_access = '1' else brm_we_i;
	brm_do_i   <= brm_ram_q;
	brm_host_q <= brm_ram_q;

end rtl;

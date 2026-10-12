--------------------------------------------------------------------------------
-- VHDL wrapper around the Gowin IP-Core-Generator "DP" (true dual port BSRAM)
-- primitive for the (addr_width=9, data_width=10) configuration used by
-- HUC6270's SPR_LINE_BUF0/SPR_LINE_BUF1.  See dpram_ip_8x16.vhd for the full
-- rationale (WRITE_MODE0/1 = Normal / 2'b00, matching nand2mario/snestang's
-- Gowin_DPB_OAM.v, to avoid the PA2122 placement failure hit by the
-- behaviourally-inferred dpram entity on this instance).
--
-- Requires the generated gowin_dpb_line.v in the project, with its top
-- module renamed from the IP Core Generator's default "Gowin_DP" to
-- "Gowin_DP_line" to avoid a name clash with the (8,16) wrapper's own
-- generated Gowin_DP module (see gowin_dpb_sat.v / dpram_ip_8x16.vhd).
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

entity dpram_ip_9x10 is
	generic (
		disable_value : std_logic := '1'
	);
	PORT
	(
		clock			: in  STD_LOGIC;
		ss_hold : in std_logic := '0';
		ss_load : in std_logic := '0';
		ss_data : in std_logic_vector(19 downto 0) := (others => '0');
		ss_q : out std_logic_vector(19 downto 0) := (others => '0');
		ss_mem_req : in std_logic := '0';
		ss_mem_we : in std_logic := '0';
		ss_mem_addr : in std_logic_vector(8 downto 0) := (others => '0');
		ss_mem_di : in std_logic_vector(9 downto 0) := (others => '0');
		ss_mem_q : out std_logic_vector(9 downto 0) := (others => '0');
		address_a	: in  STD_LOGIC_VECTOR (8 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (9 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (9 DOWNTO 0);
		cs_a        : in  std_logic := '1';

		address_b	: in  STD_LOGIC_VECTOR (8 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (9 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (9 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;

architecture STRUCT of dpram_ip_9x10 is

	component Gowin_DP_line is
		port (
			douta : out std_logic_vector(9 downto 0);
			doutb : out std_logic_vector(9 downto 0);
			clka  : in  std_logic;
			ocea  : in  std_logic;
			cea   : in  std_logic;
			reseta: in  std_logic;
			wrea  : in  std_logic;
			clkb  : in  std_logic;
			oceb  : in  std_logic;
			ceb   : in  std_logic;
			resetb: in  std_logic;
			wreb  : in  std_logic;
			ada   : in  std_logic_vector(8 downto 0);
			dina  : in  std_logic_vector(9 downto 0);
			adb   : in  std_logic_vector(8 downto 0);
			dinb  : in  std_logic_vector(9 downto 0)
		);
	end component;

	signal douta_i, doutb_i : std_logic_vector(9 downto 0);
	signal saved_a, saved_b, visible_a, visible_b : std_logic_vector(9 downto 0);
	signal valid_a, valid_b, hold_previous : std_logic := '0';
	signal addr_a : std_logic_vector(8 downto 0);
	signal data_in : std_logic_vector(9 downto 0);
	signal enable_port_a, enable_port_b, write_port_a : std_logic;

begin

	visible_a <= saved_a when valid_a = '1' else douta_i;
	visible_b <= saved_b when valid_b = '1' else doutb_i;
	q_a <= visible_a when cs_a = '1' else (others => disable_value);
	q_b <= visible_b when cs_b = '1' else (others => disable_value);
	ss_q <= visible_b & visible_a;
	ss_mem_q <= douta_i;
	addr_a <= ss_mem_addr when ss_hold = '1' else address_a;
	data_in <= ss_mem_di when ss_hold = '1' else data_a;
	enable_port_a <= ss_mem_req when ss_hold = '1' else enable_a and cs_a;
	enable_port_b <= enable_b and cs_b and not ss_hold;
	write_port_a <= ss_mem_we when ss_hold = '1' else wren_a and cs_a;
	process(clock)
	begin
		if rising_edge(clock) then
			hold_previous <= ss_hold;
			if ss_hold = '1' and ss_load = '1' then
				saved_a <= ss_data(9 downto 0); saved_b <= ss_data(19 downto 10);
				valid_a <= '1'; valid_b <= '1';
			elsif ss_hold = '1' and hold_previous = '0' then
				saved_a <= visible_a; saved_b <= visible_b;
				valid_a <= '1'; valid_b <= '1';
			elsif ss_hold = '0' then
				if enable_port_a = '1' then valid_a <= '0'; end if;
				if enable_port_b = '1' then valid_b <= '0'; end if;
			end if;
		end if;
	end process;

	u_dp : Gowin_DP_line
	port map (
		douta  => douta_i,
		doutb  => doutb_i,
		clka   => clock,
		ocea   => enable_port_a,
		cea    => enable_port_a,
		reseta => '0',
		wrea   => write_port_a,
		clkb   => clock,
		oceb   => enable_port_b,
		ceb    => enable_port_b,
		resetb => '0',
		wreb   => wren_b and cs_b,
		ada    => addr_a,
		dina   => data_in,
		adb    => address_b,
		dinb   => data_b
	);

end architecture;

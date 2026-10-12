--------------------------------------------------------------------------------
-- Portable (vendor independent) replacement for the original Altera
-- altsyncram based dpram.vhd of the TurboGrafx16_FPGA core.
--
-- The entity interfaces (names, generics, ports, defaults) are unchanged so
-- that the rest of the core does not need to be touched.  The behaviour of the
-- original altsyncram configuration is reproduced on port A:
--
--   * synchronous, unregistered output  -> read data appears one clock later
--   * read_during_write_mode = NEW_DATA -> a port reading the address it is
--     writing in the same cycle sees the new data (write-first)
--   * cs_x = '0' forces the corresponding output to `disable_value` and
--     inhibits the write
--   * enable_x acts as a clock enable
--
-- Port B intentionally does NOT reproduce the write-first/bypass behaviour.
-- Every instantiation of this entity in the core uses port B purely for a
-- clear/write sweep (CLR_A/CLR_WE-style) on one hand and independent reads on
-- the other, with the two never coinciding in time -- so the bypass was never
-- functionally required there.  GowinSynthesis maps a write-first port to a
-- WRITE_MODE setting that the BSRAM primitive on the GW2AR-18 does not
-- support (PA2122, WRITE_MODE1 = 2'b10), forcing a fallback to a much more
-- expensive LUT-based implementation.  Gowin's own IP Core Generator output
-- for a comparable dual-port RAM (see nand2mario/snestang's
-- Gowin_DPB_OAM.v) always configures WRITE_MODE0 = WRITE_MODE1 = 2'b00 (no
-- bypass), which is exactly what removing the port B bypass here reproduces
-- at the RTL level, letting plain BSRAM inference (no syn_ramstyle override
-- needed) succeed through both synthesis and place & route.
--
-- Memory initialisation: GowinSynthesis has no equivalent of altsyncram's
-- `init_file`, and VHDL file I/O is not available at elaboration time, so the
-- two .mif files used by this core have been converted into constant tables in
-- work.mem_init_pkg (see tools/mif2vhd.py).  `mem_init_file` still selects the
-- table by name, which keeps the instantiations in the core unchanged.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

library work;
use work.mem_init_pkg.all;

entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		disable_value : std_logic := '1'
	);
	PORT
	(
		clock			: in  STD_LOGIC ;
		ss_hold : in std_logic := '0';
		ss_load : in std_logic := '0';
		ss_data : in std_logic_vector(2*data_width-1 downto 0) := (others => '0');
		ss_q : out std_logic_vector(2*data_width-1 downto 0) := (others => '0');
		ss_mem_req : in std_logic := '0';
		ss_mem_we : in std_logic := '0';
		ss_mem_addr : in std_logic_vector(addr_width-1 downto 0) := (others => '0');
		ss_mem_di : in std_logic_vector(data_width-1 downto 0) := (others => '0');
		ss_mem_q : out std_logic_vector(data_width-1 downto 0) := (others => '0');
		address_a	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs_a        : in  std_logic := '1';

		address_b	: in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;


ARCHITECTURE SYN OF dpram IS

	type mem_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);

	function init_mem return mem_t is
		variable m : mem_t := (others => (others => '0'));
	begin
		if mem_init_file = "voltab_small.mif" and addr_width >= 8 and data_width <= 16 then
			for i in 0 to 255 loop
				m(i) := VOLTAB_INIT(i)(data_width-1 downto 0);
			end loop;
		elsif mem_init_file = "huc6260_palette_init.mif" and addr_width >= 9 and data_width <= 16 then
			for i in 0 to 511 loop
				m(i) := PALETTE_INIT(i)(data_width-1 downto 0);
			end loop;
		end if;
		return m;
	end function;

	signal ram : mem_t := init_mem;
	attribute syn_ramstyle : string;
	attribute syn_ramstyle of ram : signal is "block_ram";

	signal q0 : std_logic_vector((data_width - 1) downto 0);
	signal q1 : std_logic_vector((data_width - 1) downto 0);
	signal saved_q0, saved_q1, visible_q0, visible_q1 : std_logic_vector(data_width-1 downto 0);
	signal saved_valid0, saved_valid1 : std_logic := '0';
	signal hold_previous : std_logic := '0';
	signal port_a_addr : std_logic_vector(addr_width-1 downto 0);
	signal port_a_data : std_logic_vector(data_width-1 downto 0);
	signal port_a_enable, port_a_write, port_b_enable : std_logic;

BEGIN
	visible_q0 <= saved_q0 when saved_valid0 = '1' else q0;
	visible_q1 <= saved_q1 when saved_valid1 = '1' else q1;
	q_a<= visible_q0 when cs_a = '1' else (others => disable_value);
	q_b<= visible_q1 when cs_b = '1' else (others => disable_value);
	ss_q <= visible_q1 & visible_q0;
	ss_mem_q <= q0;
	port_a_addr <= ss_mem_addr when ss_hold = '1' else address_a;
	port_a_data <= ss_mem_di when ss_hold = '1' else data_a;
	port_a_enable <= ss_mem_req when ss_hold = '1' else enable_a;
	port_a_write <= ss_mem_we when ss_hold = '1' else wren_a and cs_a;
	port_b_enable <= enable_b and not ss_hold;

	process(clock)
	begin
		if rising_edge(clock) then
			hold_previous <= ss_hold;
			if ss_hold = '1' and ss_load = '1' then
				saved_q0 <= ss_data(data_width-1 downto 0);
				saved_q1 <= ss_data(2*data_width-1 downto data_width);
				saved_valid0 <= '1';
				saved_valid1 <= '1';
			elsif ss_hold = '1' and hold_previous = '0' then
				saved_q0 <= visible_q0;
				saved_q1 <= visible_q1;
				saved_valid0 <= '1';
				saved_valid1 <= '1';
			elsif ss_hold = '0' then
				if enable_a = '1' then saved_valid0 <= '0'; end if;
				if enable_b = '1' then saved_valid1 <= '0'; end if;
			end if;
		end if;
	end process;

	process (clock)
	begin
		if rising_edge(clock) then
			-- Port A: write-first / bypass preserved (CPU-facing back-to-back
			-- read-modify-write correctness relies on this).
			if port_a_enable = '1' then
				if port_a_write = '1' then
					ram(to_integer(unsigned(port_a_addr))) <= port_a_data;
					q0 <= port_a_data;
				else
					q0 <= ram(to_integer(unsigned(port_a_addr)));
				end if;
			end if;

			-- Port B: plain (no-bypass) read/write, matching Gowin BSRAM
			-- WRITE_MODE = 2'b00. See architecture header comment.
			if port_b_enable = '1' then
				if wren_b = '1' and cs_b = '1' then
					ram(to_integer(unsigned(address_b))) <= data_b;
				end if;
				q1 <= ram(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;

END SYN;

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

entity dpram_difclk is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	PORT
	(
		clock0		: in  STD_LOGIC;
		clock1		: in  STD_LOGIC;

		address_a	: in  STD_LOGIC_VECTOR (addr_width_a-1 DOWNTO 0);
		data_a		: in  STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0) := (others => '0');
		enable_a		: in  STD_LOGIC := '1';
		wren_a		: in  STD_LOGIC := '0';
		q_a			: out STD_LOGIC_VECTOR (data_width_a-1 DOWNTO 0);
		cs_a        : in  std_logic := '1';

		address_b	: in  STD_LOGIC_VECTOR (addr_width_b-1 DOWNTO 0) := (others => '0');
		data_b		: in  STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0) := (others => '0');
		enable_b		: in  STD_LOGIC := '1';
		wren_b		: in  STD_LOGIC := '0';
		q_b			: out STD_LOGIC_VECTOR (data_width_b-1 DOWNTO 0);
		cs_b        : in  std_logic := '1'
	);
end entity;


ARCHITECTURE SYN OF dpram_difclk IS

	-- Both ports address the same physical storage but are clocked
	-- independently, so the array has to be a shared variable.
	type mem_t is array (0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
	shared variable ram : mem_t := (others => (others => '0'));

	signal q0 : std_logic_vector((data_width_a - 1) downto 0);
	signal q1 : std_logic_vector((data_width_b - 1) downto 0);

BEGIN
	q_a<= q0 when cs_a = '1' else (others => '1');
	q_b<= q1 when cs_b = '1' else (others => '1');

	process (clock0)
	begin
		if rising_edge(clock0) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					ram(to_integer(unsigned(address_a))) := data_a;
					q0 <= data_a;
				else
					q0 <= ram(to_integer(unsigned(address_a)));
				end if;
			end if;
		end if;
	end process;

	process (clock1)
	begin
		if rising_edge(clock1) then
			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					ram(to_integer(unsigned(address_b))) := data_b;
					q1 <= data_b;
				else
					q1 <= ram(to_integer(unsigned(address_b)));
				end if;
			end if;
		end if;
	end process;

END SYN;

--------------------------------------------------------------
-- Single port Block RAM
--------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;

ENTITY spram IS
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM" -- kept for interface compatibility
	);
	PORT
	(
		clock   : in  STD_LOGIC;
		address : in  STD_LOGIC_VECTOR (addr_width-1 DOWNTO 0);
		data    : in  STD_LOGIC_VECTOR (data_width-1 DOWNTO 0) := (others => '0');
		enable  : in  STD_LOGIC := '1';
		wren    : in  STD_LOGIC := '0';
		q       : out STD_LOGIC_VECTOR (data_width-1 DOWNTO 0);
		cs      : in  std_logic := '1'
	);
END ENTITY;

ARCHITECTURE SYN OF spram IS
	type mem_t is array (0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	signal ram : mem_t := (others => (others => '0'));
	signal q0 : std_logic_vector((data_width - 1) downto 0);
BEGIN
	q<= q0 when cs = '1' else (others => '1');

	process (clock)
	begin
		if rising_edge(clock) then
			if enable = '1' then
				if wren = '1' and cs = '1' then
					ram(to_integer(unsigned(address))) <= data;
					q0 <= data;
				else
					q0 <= ram(to_integer(unsigned(address)));
				end if;
			end if;
		end if;
	end process;

END SYN;
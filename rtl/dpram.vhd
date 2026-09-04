--------------------------------------------------------------------------------
-- Portable (vendor independent) replacement for the original Altera
-- altsyncram based dpram.vhd of the TurboGrafx16_FPGA core.
--
-- The entity interfaces (names, generics, ports, defaults) are unchanged so
-- that the rest of the core does not need to be touched.  The behaviour of the
-- original altsyncram configuration is reproduced:
--
--   * synchronous, unregistered output  -> read data appears one clock later
--   * read_during_write_mode = NEW_DATA -> a port reading the address it is
--     writing in the same cycle sees the new data (write-first)
--   * cs_x = '0' forces the corresponding output to `disable_value` and
--     inhibits the write
--   * enable_x acts as a clock enable
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

	signal q0 : std_logic_vector((data_width - 1) downto 0);
	signal q1 : std_logic_vector((data_width - 1) downto 0);

BEGIN
	q_a<= q0 when cs_a = '1' else (others => disable_value);
	q_b<= q1 when cs_b = '1' else (others => disable_value);

	process (clock)
	begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' and cs_a = '1' then
					ram(to_integer(unsigned(address_a))) <= data_a;
					q0 <= data_a;
				else
					q0 <= ram(to_integer(unsigned(address_a)));
				end if;
			end if;

			if enable_b = '1' then
				if wren_b = '1' and cs_b = '1' then
					ram(to_integer(unsigned(address_b))) <= data_b;
					q1 <= data_b;
				else
					q1 <= ram(to_integer(unsigned(address_b)));
				end if;
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

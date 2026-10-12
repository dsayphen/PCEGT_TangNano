library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sim_gowin_ram is
    generic (ADDR_WIDTH : integer; DATA_WIDTH : integer);
    port (clk : in std_logic;
          enable_a, enable_b, write_a, write_b : in std_logic;
          addr_a, addr_b : in std_logic_vector(ADDR_WIDTH-1 downto 0);
          data_a, data_b : in std_logic_vector(DATA_WIDTH-1 downto 0);
          read_a, read_b : out std_logic_vector(DATA_WIDTH-1 downto 0));
end entity;

architecture model of sim_gowin_ram is
    type memory_t is array(0 to 2**ADDR_WIDTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal memory : memory_t := (others => (others => '0'));
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if enable_a = '1' then
                read_a <= memory(to_integer(unsigned(addr_a)));
                if write_a = '1' then memory(to_integer(unsigned(addr_a))) <= data_a; end if;
            end if;
            if enable_b = '1' then
                read_b <= memory(to_integer(unsigned(addr_b)));
                if write_b = '1' then memory(to_integer(unsigned(addr_b))) <= data_b; end if;
            end if;
        end if;
    end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
entity Gowin_DP is
    port (douta, doutb : out std_logic_vector(15 downto 0);
          clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb : in std_logic;
          ada, adb : in std_logic_vector(7 downto 0);
          dina, dinb : in std_logic_vector(15 downto 0));
end entity;
architecture model of Gowin_DP is
begin
    assert clka = clkb report "SAT test model requires common clocks" severity failure;
    memory : entity work.sim_gowin_ram generic map (8, 16)
        port map (clka, cea and ocea, ceb and oceb, wrea, wreb,
                  ada, adb, dina, dinb, douta, doutb);
end architecture;

library ieee;
use ieee.std_logic_1164.all;
entity Gowin_DP_line is
    port (douta, doutb : out std_logic_vector(9 downto 0);
          clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb : in std_logic;
          ada, adb : in std_logic_vector(8 downto 0);
          dina, dinb : in std_logic_vector(9 downto 0));
end entity;
architecture model of Gowin_DP_line is
begin
    assert clka = clkb report "Line RAM test model requires common clocks" severity failure;
    memory : entity work.sim_gowin_ram generic map (9, 10)
        port map (clka, cea and ocea, ceb and oceb, wrea, wreb,
                  ada, adb, dina, dinb, douta, doutb);
end architecture;
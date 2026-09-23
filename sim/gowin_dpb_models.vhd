library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Gowin_DP is
    port (
        douta : out std_logic_vector(15 downto 0);
        doutb : out std_logic_vector(15 downto 0);
        clka : in std_logic;
        ocea : in std_logic;
        cea : in std_logic;
        reseta : in std_logic;
        wrea : in std_logic;
        clkb : in std_logic;
        oceb : in std_logic;
        ceb : in std_logic;
        resetb : in std_logic;
        wreb : in std_logic;
        ada : in std_logic_vector(7 downto 0);
        dina : in std_logic_vector(15 downto 0);
        adb : in std_logic_vector(7 downto 0);
        dinb : in std_logic_vector(15 downto 0)
    );
end entity;

architecture simulation of Gowin_DP is
    type memory_t is array (0 to 255) of std_logic_vector(15 downto 0);
    signal memory : memory_t := (others => (others => '0'));
begin
    process (clka)
    begin
        if rising_edge(clka) and cea = '1' then
            if wrea = '1' then
                memory(to_integer(unsigned(ada))) <= dina;
            end if;
            if ocea = '1' then
                douta <= memory(to_integer(unsigned(ada)));
            end if;
        end if;
    end process;

    process (clkb)
    begin
        if rising_edge(clkb) and ceb = '1' then
            if wreb = '1' then
                memory(to_integer(unsigned(adb))) <= dinb;
            end if;
            if oceb = '1' then
                doutb <= memory(to_integer(unsigned(adb)));
            end if;
        end if;
    end process;
end architecture;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity Gowin_DP_line is
    port (
        douta : out std_logic_vector(9 downto 0);
        doutb : out std_logic_vector(9 downto 0);
        clka : in std_logic;
        ocea : in std_logic;
        cea : in std_logic;
        reseta : in std_logic;
        wrea : in std_logic;
        clkb : in std_logic;
        oceb : in std_logic;
        ceb : in std_logic;
        resetb : in std_logic;
        wreb : in std_logic;
        ada : in std_logic_vector(8 downto 0);
        dina : in std_logic_vector(9 downto 0);
        adb : in std_logic_vector(8 downto 0);
        dinb : in std_logic_vector(9 downto 0)
    );
end entity;

architecture simulation of Gowin_DP_line is
    type memory_t is array (0 to 511) of std_logic_vector(9 downto 0);
    signal memory : memory_t := (others => (others => '0'));
begin
    process (clka)
    begin
        if rising_edge(clka) and cea = '1' then
            if wrea = '1' then
                memory(to_integer(unsigned(ada))) <= dina;
            end if;
            if ocea = '1' then
                douta <= memory(to_integer(unsigned(ada)));
            end if;
        end if;
    end process;

    process (clkb)
    begin
        if rising_edge(clkb) and ceb = '1' then
            if wreb = '1' then
                memory(to_integer(unsigned(adb))) <= dinb;
            end if;
            if oceb = '1' then
                doutb <= memory(to_integer(unsigned(adb)));
            end if;
        end if;
    end process;
end architecture;

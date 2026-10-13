# Caractères de tracé de cadres (OSD PC Engine GT)

Afin de permettre l'affichage de menus avec des bordures et cadres dans l'OSD tout en respectant les fortes contraintes de ressources mémoire du FPGA Tang Nano 20K (espace réservé pour 96 glyphes ASCII de `0x20` à `0x7F` en ROM16), plusieurs caractères ASCII inutilisés ont été remappés vers des symboles de dessin de boîtes et de blocs.

---

## Table de correspondance

| Caractère ASCII | Code Hex | Symbole visuel | Nom / Rôle | Motif 8x8 |
| :---: | :---: | :---: | :--- | :--- |
| `` ` `` *(backtick)* | `0x60` | `┌` | Coin haut gauche | Ligne centrale vers la droite + descente |
| `^` *(circonflexe)* | `0x5E` | `┐` | Coin haut droit | Ligne centrale vers la gauche + descente |
| `{` *(accolade ouvrante)* | `0x7B` | `└` | Coin bas gauche | Montée + ligne centrale vers la droite |
| `}` *(accolade fermante)* | `0x7D` | `┘` | Coin bas droit | Montée + ligne centrale vers la gauche |
| `~` *(tilde)* | `0x7E` | `─` | Ligne horizontale | Ligne continue de bord à bord (épaisseur 2 px) |
| `\|` *(pipe)* | `0x7C` | `│` | Ligne verticale | Ligne continue de haut en bas (épaisseur 2 px) |
| `\` *(antislash)* | `0x5C` | `├` | T gauche (jonction) | Ligne verticale + branche vers la droite |
| `\x7F` *(DEL)* | `0x7F` | `┤` | T droit (jonction) | Ligne verticale + branche vers la gauche |
| `_` *(underscore)* | `0x5F` | `█` | Bloc plein (8x8) | Carré plein 8x8 (jauges remplies, sélections) |
| `$` *(dollar)* | `0x24` | `░` | Trame / ombre (8x8) | Damier 50% en quinconce (fond de jauge, curseur atténué) |

---

## Exemples d'utilisation dans le Firmware (`menu.c`, `browser.c`, etc.)

L'OSD fait **32 colonnes de large**.

### 1. Encadrement d'un menu ou pop-up
```c
// Ligne du haut (32 caractères) : ┌──────────────────────────────┐
print("`~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^");

// Lignes intermédiaires : │        Menu Principal        │
print("|        Menu Principal        |");

// Ligne de séparation : ├──────────────────────────────┤
print("\\~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\x7F");

// Contenu : │ 1. Lancer le jeu             │
print("| 1. Lancer le jeu             |");

// Ligne du bas : └──────────────────────────────┘
print("{~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~}");
```

### 2. Jauge de progression ou volume
```c
// Exemple à 50% : [████████░░░░░░░░] 50%
print("[________$$$$$$$$] 50%");
```

---

## Régénération automatique

Les définitions matricielles sources se trouvent dans `tools/font8x8_basic.txt`.
Pour recompiler la ROM Verilog utilisée par la synthèse Gowin (`rtl/tang/iosys/font_rom.v`) :

```powershell
python tools/gen_font_rom.py
```

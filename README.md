# Stahovač fotogalerie Naše MŠ

Hromadně stáhne **všechny** fotky z fotogalerie rodičovského účtu
[Naše MŠ](https://nasems.cz) (`nasems.cz`) do vašeho počítače a zachová přitom původní
strukturu složek (alb).

K dispozici jsou dvě rovnocenné varianty — použijte tu, která vám vyhovuje:

| Skript | Prostředí | Potřebuje |
|---|---|---|
| `download_nasems.ps1` | Windows PowerShell 5.1+ | nic navíc (čistý PowerShell) |
| `download_nasems.sh` | Bash | `curl`, `jq`, `file` (součást Git Bash / Linux / macOS) |

> 🇬🇧 English version: [README.en.md](README.en.md)

---

## Co skript dělá

Galerie nejsou obyčejné odkazy — načítají se dynamicky (AJAX) a jsou **vnořené**:
složky obsahují podsložky, které nakonec obsahují alba s fotkami. Skript:

1. **Přihlásí se** vašimi údaji a podrží přihlašovací session (cookie).
2. **Projde rekurzivně celý strom složek** (stejné AJAX dotazy, jaké dělá web, když na
   složku kliknete).
3. U každého alba stáhne fotku v **plné velikosti** (odkaz z lightboxu, ne náhled) a
   uloží ji do `photos/<Složka>/<Podsložka>/<Album>/`.
4. Zrcadlí původní názvy složek a očistí znaky, které nejsou na disku povolené.

Výsledkem je kompletní lokální kopie galerie, kterou si můžete prohlížet, zálohovat
nebo archivovat.

## Použití

### PowerShell (Windows)

```powershell
# doporučeno: přihlašovací údaje přes proměnné prostředí
$env:NASEMS_LOGIN    = 'vase-prihlaseni'
$env:NASEMS_PASSWORD = 'vase-heslo'
powershell -ExecutionPolicy Bypass -File .\download_nasems.ps1 *> download.log

# nebo jako parametry
.\download_nasems.ps1 -Login vase-prihlaseni -Password vase-heslo

# nebo skript jen spusťte a on se zeptá
.\download_nasems.ps1
```

### Bash (Git Bash ve Windows, Linux, macOS)

```bash
# doporučeno: proměnné prostředí
NASEMS_LOGIN=vase-prihlaseni NASEMS_PASSWORD=vase-heslo ./download_nasems.sh > download.log 2>&1

# nebo jako argumenty
./download_nasems.sh vase-prihlaseni vase-heslo

# nebo skript jen spusťte a on se zeptá
./download_nasems.sh
```

Fotky se ukládají do podsložky `photos/` vedle skriptu. Průběh se vypisuje s časovými
značkami; pokud chcete log, přesměrujte výstup do souboru (jak je ukázáno výše).

> **Jiná školka / jiná adresa?** Nastavte `NASEMS_URL` (např. `NASEMS_URL=https://nasems.cz`).
> Výchozí hodnota je `https://nasems.cz`.

## Opakované spuštění a pokračování

Skript je **bezpečné spustit znovu**. Přeskočí každou fotku, která už existuje jako
neprázdný soubor, takže přerušený běh (zavřené okno, restart, výpadek připojení) prostě
naváže tam, kde skončil — žádné duplikáty, žádné stahování znovu.

## Výstupní soubory

| Cesta | Význam |
|---|---|
| `photos/…` | Stažená galerie, zrcadlí strom alb |
| `download.log` | Log běhu s časovými značkami (jen pokud přesměrujete výstup) |
| `broken_on_server.txt` | Fotky, které jsou **na serveru prázdné** (viz níže) |
| `failed_transient.txt` | Fotky, které selhaly dočasně — stačí spustit znovu |

## Poznámky a známé zvláštnosti

- **Odolnost proti výpadkům.** Když vyprší session nebo zakolísá připojení, skript se
  automaticky znovu přihlásí a každou fotku několikrát zkusí stáhnout.
- **Fotky „rozbité na serveru".** Některé fotky jsou na serveru uložené jako **0 bajtů**
  — server vrátí `HTTP 200`, ale žádná data neposílá, a to jak u plné velikosti, tak u
  náhledu. Takové fotky nedokáže stáhnout žádný nástroj ani prohlížeč; jsou vypsané v
  `broken_on_server.txt`, abyste mohli školku požádat o jejich nové nahrání.
- **Stejné názvy složek.** Pokud mají dvě sousední složky stejný název (galerie to
  umožňuje — a Windows navíc názvy nerozlišuje podle velikosti písmen, např.
  `HRUŠTIČKA` vs `Hruštička`), první si název ponechá a každá další dostane příponu
  `_2`, `_3`, … takže každé album skončí ve své vlastní samostatné složce. Číslování
  jde podle pořadí v galerii, takže zůstává stejné i při opakovaném spuštění.
- **Názvy souborů.** Každý soubor se jmenuje `NNNNN_<id-fotky>.<přípona>` (pořadové
  číslo v rámci alba + vlastní id z galerie) a typ (jpg/png/gif/webp) se rozpozná podle
  obsahu souboru.

## Bezpečnost

Skripty **neobsahují žádné přihlašovací údaje**. Zadávají se až při spuštění přes
proměnné prostředí, parametry, nebo interaktivní dotaz. Vygenerované soubory
`.cookies.txt`, `*.log`, složka `photos/` a manifesty jsou vyloučené přes `.gitignore`
a neměly by se commitovat.

## Upozornění

Určeno ke stažení **vlastních** fotek z galerie, ke které máte **oprávněný přístup**
(např. školka vašeho dítěte). Respektujte podmínky používání webu a soukromí ostatních
osob, které mohou být na fotkách zachycené.

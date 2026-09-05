# Algomim Mascot releases

This public repository is the release channel for **Algomim Mascot**, the
Windows desktop agent that signs in to Algomim and works with supported CAD
applications.

## Latest beta

**0.1.0.26** · Windows x64

[Download Algomim Mascot Beta](https://github.com/algomim/release/releases/download/mascot-v0.1.0.26/Algomim-Mascot-Beta-Setup-0.1.0.26-x64.exe)

The beta installer is currently unsigned, so Windows may show an
**Unknown publisher** warning. Verify the installer before running it:

```text
SHA-256  71036FCEF818E318BF0DEF28FC550092D98F6DB7A8900786EE29EF2E7EE297B4
```

Release build, 1320 automated tests and the production model/tool smoke check passed.
Exact-installer clean-install, upgrade and uninstall checks have not been completed for this beta.

The application reads [`mascot/latest.json`](mascot/latest.json) when the user
chooses **Check for updates**. It accepts only HTTPS installers published from
this repository and verifies the downloaded file against that manifest before
opening it.

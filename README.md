# Algomim Mascot releases

This public repository is the release channel for **Algomim Mascot**, the
Windows desktop agent that signs in to Algomim and works with supported CAD
applications.

## Latest beta

**0.1.0.20** · Windows x64

[Download Algomim Mascot Beta](https://github.com/algomim/release/releases/download/mascot-v0.1.0.20/Algomim-Mascot-Beta-Setup-0.1.0.20-x64.exe)

The beta installer is currently unsigned, so Windows may show an
**Unknown publisher** warning. Verify the installer before running it:

```text
SHA-256  46D2393417776093281FCA13D924A2D9515E7610E10353A70358492750A6101B
```

The application reads [`mascot/latest.json`](mascot/latest.json) when the user
chooses **Check for updates**. It accepts only HTTPS installers published from
this repository and verifies the downloaded file against that manifest before
opening it.

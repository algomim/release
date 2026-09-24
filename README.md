# Algomim Mascot releases

This public repository is the release channel for **Algomim Mascot**, the
Windows desktop agent that connects to your chosen AI provider and works with
supported CAD applications.

## Latest beta

**0.1.0.32** · Windows x64

[Download Algomim Mascot Beta](https://github.com/algomim/release/releases/download/mascot-v0.1.0.32/Algomim-Mascot-Beta-Setup-0.1.0.32-x64.exe)

The beta installer is currently unsigned, so Windows may show an
**Unknown publisher** warning. Verify the installer before running it:

```text
SHA-256  E3F1A977B3288BB1AE60F7DC5A8F7681A08C8ABA7D41038909B57A3B63CD01B2
```

The application reads [`mascot/latest.json`](mascot/latest.json) automatically and when the user
chooses **Check for updates**. It accepts only HTTPS installers published from
this repository and verifies the downloaded file against that manifest before
opening it.

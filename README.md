# Algomim Mascot releases

This public repository is the release channel for **Algomim Mascot**, the
Windows desktop agent that connects to your chosen AI provider and works with
supported CAD applications.

## Latest beta

**0.1.0.33** · Windows x64

[Download Algomim Mascot Beta](https://github.com/algomim/release/releases/download/mascot-v0.1.0.33/Algomim-Mascot-Beta-Setup-0.1.0.33-x64.exe)

The beta installer is currently unsigned, so Windows may show an
**Unknown publisher** warning. Verify the installer before running it:

```text
SHA-256  56ADF3F5D641DE8ABDABF6BE6F5A8D67DCEF7E2AA82100D24586BC09133D7A73
```

The application reads [`mascot/latest.json`](mascot/latest.json) automatically and when the user
chooses **Check for updates**. It accepts only HTTPS installers published from
this repository and verifies the downloaded file against that manifest before
opening it.

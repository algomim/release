# Algomim Mascot releases

This public repository is the release channel for **Algomim Mascot**, the
Windows desktop agent that signs in to Algomim and works with supported CAD
applications.

## Latest beta

**0.1.0.24** · Windows x64

[Download Algomim Mascot Beta](https://github.com/algomim/release/releases/download/mascot-v0.1.0.24/Algomim-Mascot-Beta-Setup-0.1.0.24-x64.exe)

The beta installer is currently unsigned, so Windows may show an
**Unknown publisher** warning. Verify the installer before running it:

```text
SHA-256  C90DCBD04A45D197EB32C2564C651D41ED28981E1AB34B02DA8832AF70FE9EED
```

The application reads [`mascot/latest.json`](mascot/latest.json) when the user
chooses **Check for updates**. It accepts only HTTPS installers published from
this repository and verifies the downloaded file against that manifest before
opening it.

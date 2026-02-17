# Localias on GitHub Actions

This GitHub Action installs and configures [Localias](https://github.com/peterldowns/localias) to enable HTTPS domains for CI tests. It handles certificate installation and system configuration to ensure proper HTTPS functionality in testing environments.

[This was extracted from this python repo](https://github.com/iloveitaly/python-starter-template), if you are looking for an example of how to integrate this into your project.

## Features

- Installs and runs Localias as a daemon
- Configures system CA certificates
- Sets up NSS database for Chrome/Chromium compatibility (for playright, cypress, etc)
- Validates HTTPS functionality with curl tests based on a domain in `.localias.yml`

## Usage

```yaml
steps:
  - uses: iloveitaly/github-action-localias@master
    with:
      # Optional: warm the chromium database by visiting each host with a headless browser
      chrome: true
    env:
      # Optional: use a custom path to a localias configuration file
      LOCALIAS_CONFIGFILE: .localias.yml
```

## Development Notes

Getting this working was challenging:

* You'll see an error message (with a typo) `not NSS security databases found` even if the NSS DB exists. This occurs
  even under `sudo -E` and it really shouldn't [because the directory it references definitely exists](https://github.com/smallstep/truststore/blob/d71bcdef66e239112d877b3e531e1011795efdf7/truststore_nss.go#L16).
* `curl` will succeed if retried multiple times. I have no idea why this is happening. There must be some CA store refresh process which runs async. Rather than trying to understand what is going on, we just retry a handful of times.
  * Note that this happens on each unique domain. So it's not related to the cert cache globally, there's some per-host cert system that needs to be warmed up. This is why we iterate over each domain.
* Installing `libnss3-tools` does not initialize the NSS DB. You must do this manually.
* `curl` does not use the NSS DB but Chromium does.
* `sudo localias debug cert --print | sudo tee -a /etc/ssl/certs/ca-certificates.crt` executes correctly with caddy, this is not necessary.
* This struggles with mise-installed localias because of the mise trust database and the sudo requirement. This is why a custom installed localias is recommended.

### Helpful links

* https://ray.run/questions/how-do-i-fix-ssl-errors-when-using-playwright-and-google-chrome-to-access-a-site-on-localhost-3000
* https://medium.com/@mudit94/configuring-https-certificates-in-playwright-932ca3fc9f06
* https://superuser.com/questions/1083766/how-do-i-deal-with-neterr-cert-authority-invalid-in-chrome

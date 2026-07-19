# Runbook migrazione: WireGuard → Cloudflare Tunnel + Authentik

Guida operativa passo-passo per applicare la migrazione. I file GitOps sono già stati creati/modificati in questo commit (vedi elenco in fondo). Questo documento copre **tutto ciò che devi fare tu a mano**: comandi da terminale, click nel dashboard Cloudflare/Authentik, modifiche al router.

Segui le fasi **nell'ordine indicato**. Non saltare avanti: WireGuard resta attivo e funzionante fino alla Fase 7 apposta, come rete di sicurezza nel caso qualcosa nel tunnel non funzioni durante i test.

---

## Prerequisiti locali

```bash
brew install cloudflared kubeseal
```

Assicurati che `kubectl` punti già al cluster giusto (`kubectl config current-context`).

---

## Fase 0 — Sealed Secrets

Il file `argo/applications/sealed-secrets.yaml` è già pronto.

1. Committa e pusha:
   ```bash
   git add argo/applications/sealed-secrets.yaml
   git commit -m "feat: deploy sealed-secrets controller"
   git push
   ```
2. Attendi il sync (ArgoCD fa self-heal automatico entro ~3 minuti, oppure forza da CLI/UI):
   ```bash
   kubectl -n sealed-secrets get pods -w
   ```
   Aspetta che il pod `sealed-secrets-controller-...` sia `Running`.
3. **Backup della chiave privata — fallo subito, non rimandare**:
   ```bash
   kubectl get secret -n sealed-secrets \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o yaml > ~/sealed-secrets-master.key
   ```
   Sposta `~/sealed-secrets-master.key` in un posto sicuro **fuori da git** (password manager, chiavetta cifrata offline). Se la perdi, ogni `SealedSecret` che committerai in futuro sarà indecifrabile per sempre e dovrai rigenerare tutto da zero.
4. Verifica che `kubeseal` trovi il controller:
   ```bash
   kubeseal --controller-name sealed-secrets-controller --controller-namespace sealed-secrets --fetch-cert > /tmp/pub-cert.pem
   ```
   Se stampa un certificato, sei pronto.

---

## Fase 1 — Cloudflare Tunnel

### 1.1 Crea il tunnel (una tantum, fuori da git)

```bash
cloudflared tunnel login
# si apre il browser, autorizza la zona mbianchi.me

cloudflared tunnel create homelab
# output tipo:
#   Created tunnel homelab with id 5f1a2b3c-....
#   Credentials written to /Users/marco.bianchi/.cloudflared/5f1a2b3c-....json
```

Annota il `<TUNNEL_ID>` stampato.

### 1.2 Aggiorna il ConfigMap con il TUNNEL_ID reale

Apri `argo/apps/cloudflared/configmap.yaml` e sostituisci `TUNNEL_ID_PLACEHOLDER` con il tuo `<TUNNEL_ID>`:
```bash
sed -i '' "s/TUNNEL_ID_PLACEHOLDER/<TUNNEL_ID>/" argo/apps/cloudflared/configmap.yaml
```

### 1.3 Sigilla le credenziali del tunnel

```bash
kubectl create secret generic tunnel-credentials \
  --namespace cloudflare-tunnel \
  --from-file=credentials.json=/Users/marco.bianchi/.cloudflared/<TUNNEL_ID>.json \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
> argo/apps/cloudflared/sealedsecret-tunnel-credentials.yaml
```
(Il namespace `cloudflare-tunnel` non esiste ancora sul cluster in questo momento — va bene comunque, `kubeseal` non ha bisogno che il namespace esista già, cifra solo in base al nome.)

### 1.4 Committa e pusha

```bash
git add argo/applications/cloudflared.yaml argo/apps/cloudflared/
git commit -m "feat: deploy cloudflare tunnel"
git push
```

### 1.5 Verifica

```bash
kubectl -n cloudflare-tunnel get pods -w
# attesi 2 pod cloudflared Running

cloudflared tunnel info homelab
# atteso: 2 connessioni attive (una per pod)
```

**Non toccare ancora il router né le DNS** — il tunnel esiste ma non ha ancora traffico instradato.

---

## Fase 2 — DNS Cloudflare (dashboard)

Vai su **Cloudflare Dashboard → mbianchi.me → DNS → Records**.

| Azione | Tipo | Nome | Target | Proxy |
|---|---|---|---|---|
| Modifica | A → **CNAME** | `@` (apex, mbianchi.me) | `<TUNNEL_ID>.cfargotunnel.com` | 🟠 ON (proxied) |
| Modifica | A → **CNAME** | `www` | `<TUNNEL_ID>.cfargotunnel.com` | 🟠 ON (proxied) |
| Modifica | A → **CNAME** | `*` | `<TUNNEL_ID>.cfargotunnel.com` | 🟠 ON (proxied) |
| **Non toccare ancora** | A | `vpn` | `95.110.183.54` | ⚪ OFF | ← lasciare fino alla Fase 7 |

Se il tuo piano Cloudflare permette CNAME flattening sull'apex (di default sì), il record `@` come CNAME funziona senza problemi.

Poi vai su **SSL/TLS → Overview** e imposta la modalità su **Full** (non "Full (strict)", perché nginx presenta un certificato Let's Encrypt valido comunque, ma "Full" è sufficiente e più tollerante).

### Verifica propagazione

```bash
dig +short mbianchi.me
dig +short home.mbianchi.me
# atteso: IP Cloudflare (non più 95.110.183.54)
```

---

## Fase 3 — Authentik

### 3.1 Genera i segreti e sigillali

> Nota: il chart `authentik` alla versione pinnata (2026.5.5) non ha più una subchart Redis (il progetto l'ha rimossa come dipendenza) — serve solo Postgres, niente `REDIS_PASS`.

```bash
SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')
PG_PASS=$(openssl rand -base64 32 | tr -d '\n')
BOOTSTRAP_PASS=$(openssl rand -base64 24 | tr -d '\n')
BOOTSTRAP_TOKEN=$(openssl rand -base64 32 | tr -d '\n')

kubectl create secret generic authentik-secrets \
  --namespace authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$PG_PASS" \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="marco.bianchi@docebo.com" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASS" \
  --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$BOOTSTRAP_TOKEN" \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace sealed-secrets \
  --format yaml \
> argo/apps/authentik/sealedsecret-authentik-secrets.yaml
```

**Salva `$BOOTSTRAP_PASS` e `$BOOTSTRAP_TOKEN` in un password manager** — ti servono per il primo login come `akadmin` al passo 3.3. Dopo aver eseguito il comando sopra, puoi far sparire le variabili dalla shell (`unset SECRET_KEY PG_PASS BOOTSTRAP_PASS BOOTSTRAP_TOKEN`).

Se hai già creato il secret con `AUTHENTIK_REDIS__PASSWORD` prima di questa correzione, non serve rifarlo: quella chiave in più è semplicemente ignorata, nessun bisogno di rigenerare nulla.

### 3.2 Committa e pusha

```bash
git add argo/applications/authentik-secrets.yaml argo/applications/authentik.yaml argo/apps/authentik/
git commit -m "feat: deploy authentik"
git push
```

### 3.3 Verifica il deploy

```bash
kubectl -n authentik get pods -w
```
Attendi che i pod di Authentik (server/worker) e i subchart Postgres/Redis siano `Running` (può richiedere qualche minuto per le migrazioni al primo avvio).

⚠️ **Prima di procedere**: verifica i nomi esatti dei Service creati dai subchart Bitnami, potrebbero differire leggermente dalla versione del chart pinnata in `argo/applications/authentik.yaml`:
```bash
kubectl -n authentik get svc
```
Se `authentik-postgresql` o `authentik-redis-master` non corrispondono, modifica `authentik.postgresql.host` / `authentik.redis.host` nei values di `argo/applications/authentik.yaml` e ripusha.

Poi apri `https://auth.mbianchi.me` nel browser (dovrebbe già funzionare tramite il tunnel) e fai login come `akadmin` con `AUTHENTIK_BOOTSTRAP_EMAIL`/`AUTHENTIK_BOOTSTRAP_PASSWORD` salvati sopra.

### 3.4 Setup manuale nell'interfaccia Authentik (non è in git, vive nel DB di Authentik)

1. **Applications → Providers → Create**:
   - Type: **Proxy Provider**
   - Modalità: **Forward auth (domain level)**
   - Authorization flow: `default-provider-authorization-implicit-consent` (default)
   - External host: `https://auth.mbianchi.me`
   - Cookie domain: `mbianchi.me`
   - Salva.
2. **Applications → Applications → Create**:
   - Name: es. "Homelab"
   - Slug: es. `homelab`
   - Provider: quello appena creato.
   - Salva.
3. **Applications → Outposts**:
   - Apri l'`authentik Embedded Outpost`.
   - Nella lista "Applications", seleziona/aggiungi l'Application creata al punto 2.
   - Salva. Dopo qualche secondo dovrebbe comparire il Service Kubernetes:
     ```bash
     kubectl -n authentik get svc | grep outpost
     ```
     Verifica che il nome corrisponda a quello già usato nelle annotazioni (`ak-outpost-authentik-embedded-outpost`); se differisce, aggiorna l'annotazione `auth-url` in tutti gli ingress elencati al punto 3.5 sotto.

### 3.5 Verifica il forward-auth

Le annotazioni sono già applicate su questi file (già modificati in questo commit): `argo/apps/homepage/ingress.yaml`, `argo/apps/pihole/ingress.yaml`, `argo/apps/transmission/ingress.yaml`, `argo/apps/frigate/ingress.yaml`, `argo/apps/radarr/deployment.yaml`, `argo/apps/sonarr/deployment.yaml`, `argo/apps/prowlarr/deployment.yaml`, `argo/apps/bazarr/deployment.yaml`. Sono già stati rimossi anche i whitelist da `argo/apps/argocd-ingress/ingress.yaml`, `argo/apps/immich/ingress.yaml`, `argo/apps/nextcloud/ingress.yaml`, `argo/apps/paperless/ingress.yaml`, `argo/apps/home-assistant/ingress.yaml` (questi ultimi 5 **non** hanno annotazioni auth-*, vedi Fase 3.6 e Fase 4).

Committa e pusha tutte queste modifiche già pronte insieme (se non l'hai già fatto):
```bash
git add argo/apps/argocd-ingress/ingress.yaml argo/apps/homepage/ingress.yaml argo/apps/pihole/ingress.yaml \
        argo/apps/transmission/ingress.yaml argo/apps/frigate/ingress.yaml argo/apps/immich/ingress.yaml \
        argo/apps/nextcloud/ingress.yaml argo/apps/paperless/ingress.yaml argo/apps/home-assistant/ingress.yaml \
        argo/apps/radarr/deployment.yaml argo/apps/sonarr/deployment.yaml argo/apps/prowlarr/deployment.yaml \
        argo/apps/bazarr/deployment.yaml argo/apps/homepage/configmap.yaml
git commit -m "feat: replace VPN whitelist with Authentik forward-auth / OIDC / Cloudflare Access; update homepage"
git push
```

Poi apri da browser (in incognito, per non riusare la sessione Authentik già loggata) `https://home.mbianchi.me` o `https://pihole.mbianchi.me`: deve reindirizzarti a `auth.mbianchi.me`, farti loggare, e riportarti sulla pagina originale.

⚠️ **Finestra di rischio**: da quando pusci questo commit a quando hai completato la 3.4, i servizi con le annotazioni auth-* **falliscono le richieste** (auth-url non risponde ancora) finché l'outpost non è assegnato — è il comportamento "fail closed" atteso, non un errore da correggere: gli utenti vedranno un 502/503 finché non completi 3.4, non un accesso libero. Se preferisci evitare questa finestra, fai prima 3.1-3.4, poi pusci le modifiche agli ingress.

### 3.6 OIDC nativo per ArgoCD, Immich, Nextcloud, Paperless

Per ciascuno di questi 4 servizi, crea in Authentik un **OAuth2/OpenID Provider** dedicato (Applications → Providers → Create → tipo **OAuth2/OpenID Provider**), poi un'Application collegata. Per ognuno ti servirà annotare **Client ID** e **Client Secret** generati da Authentik.

#### ArgoCD
1. In Authentik: Provider OAuth2, redirect URI `https://argo.mbianchi.me/auth/callback`, scope `openid profile email`.
2. Modifica il ConfigMap `argocd-cm` (non è tracciato in questo repo — ArgoCD stesso è stato installato fuori da GitOps):
   ```bash
   kubectl -n argocd edit configmap argocd-cm
   ```
   Aggiungi:
   ```yaml
   data:
     url: https://argo.mbianchi.me
     dex.config: |
       connectors:
         - type: oidc
           id: authentik
           name: Authentik
           config:
             issuer: https://auth.mbianchi.me/application/o/argocd/
             clientID: <CLIENT_ID>
             clientSecret: <CLIENT_SECRET>
             insecureEnableGroups: true
             scopes: ["openid", "profile", "email"]
   ```
3. Riavvia Dex:
   ```bash
   kubectl -n argocd rollout restart deployment argocd-dex-server
   ```
4. Verifica: `argocd login argo.mbianchi.me --sso` dalla CLI e login da browser mostrano il pulsante "Log in via Authentik".

#### Immich
1. In Authentik: Provider OAuth2, redirect URI `https://immich.mbianchi.me/auth/login`, scope `openid profile email`.
2. In Immich: **Administration → Settings → OAuth**, abilita, incolla Issuer URL (`https://auth.mbianchi.me/application/o/immich/`), Client ID/Secret, salva.
3. Verifica login da web e da app mobile (pulsante "Login with OAuth").

#### Nextcloud
1. In Authentik: Provider OAuth2, redirect URI `https://nextcloud.mbianchi.me/apps/user_oidc/code`.
2. In Nextcloud: installa l'app **user_oidc** (Apps → Security), poi Impostazioni → OIDC → aggiungi provider con Issuer/Client ID/Secret.
3. Verifica login da web; i client desktop/mobile di sync continuano a usare le app-password esistenti, non toccati.

#### Paperless-ngx
1. Aggiungi al Deployment di Paperless (`argo/apps/paperless/`) la variabile d'ambiente `PAPERLESS_ENABLE_HTTP_REMOTE_USER: "true"` e `PAPERLESS_LOGOUT_REDIRECT_URL`.
2. Aggiungi all'ingress di Paperless (`argo/apps/paperless/ingress.yaml`) le sole annotazioni `auth-url`/`auth-signin`/`auth-snippet` (senza bisogno di `auth-response-headers` completo) più uno snippet che propaga `X-authentik-username` come header `Remote-User` atteso da Paperless — verifica la sintassi esatta nella documentazione Paperless-ngx (`HTTP_REMOTE_USER` doc) al momento dell'implementazione, perché il nome header/variabile può differire tra versioni.

---

## Fase 4 — Home Assistant: Cloudflare Access

Nel dashboard Cloudflare, sezione **Zero Trust → Access → Applications**:

1. **Add an application → Self-hosted**.
   - Application domain: `homeassistant.mbianchi.me`.
   - Session duration: 24h (o a piacere).
2. **Policy**: Add policy → Action **Allow** → Include: `Emails` → `marco.bianchi@docebo.com` (aggiungi altri indirizzi se serve) → login method **One-Time PIN**.
3. **Zero Trust → Access → Service Auth → Service Tokens → Create Service Token**.
   - Nome: `ha-companion-app`.
   - **Copia subito Client ID e Client Secret** (il secret è mostrato una sola volta).
4. Torna sull'Access Application di HA → aggiungi una seconda **Policy**: Action **Service Auth** → Include: `Service Token` → `ha-companion-app`.
5. Sull'app Home Assistant companion (telefono): **Impostazioni → Companion App → [la tua istanza] → Configure Cloudflare Access** → incolla Client ID/Secret dal punto 3.

Verifica: da browser, `https://homeassistant.mbianchi.me` chiede l'OTP via email; dall'app companion col token configurato, l'accesso è diretto.

Nota: non serve nessuna modifica alla VM Home Assistant stessa — `http.trusted_proxies` resta invariato.

---

## Fase 5 — Verifica end-to-end (da fuori casa)

Disattiva il WiFi, usa la connessione dati del telefono (o un hotspot), e verifica:

```bash
curl -I https://mbianchi.me
curl -I https://home.mbianchi.me        # deve redirigere ad auth.mbianchi.me
curl -I https://plex.mbianchi.me        # pubblico, nessun redirect
curl -I https://ntfy.mbianchi.me        # pubblico, nessun redirect
curl -I https://homeassistant.mbianchi.me   # deve chiedere Cloudflare Access
```

Testa anche da browser reale login SSO completo su almeno un servizio forward-auth, `argocd login` via SSO, l'app mobile Immich, il client Nextcloud desktop.

**Non procedere alla Fase 6/7 finché tutto questo non funziona.**

---

## Fase 6 — Rimuovi i port-forward router (UniFi)

Solo ora, con il tunnel verificato:

1. UniFi Network → Settings → Internet → Port Forwarding.
2. Rimuovi la regola `80/443 TCP → 10.0.20.200`.
3. Rimuovi la regola `51820 UDP → 10.0.20.202`.
4. Riverifica di nuovo tutti gli hostname da rete esterna (stessi comandi della Fase 5) — ora il tunnel è l'unico percorso possibile.

---

## Fase 7 — Decommissiona WireGuard

Solo dopo la Fase 6 verificata con successo:

```bash
git rm -r argo/apps/wireguard
git rm argo/applications/wireguard.yaml
git commit -m "chore: decommission wireguard, replaced by cloudflare tunnel"
git push
```

Poi:
```bash
kubectl get pods -n wireguard
# atteso: nessuna risorsa (namespace rimosso da ArgoCD prune)

kubectl get secret -A | grep wg-easy
# se resta qualcosa, elimina manualmente: kubectl delete secret wg-easy-secret -n wireguard
```

Nel dashboard Cloudflare, elimina il record DNS `vpn` (A → 95.110.183.54).

Su Pi-hole, non è necessario alcun intervento: gli override dnsmasq `*.mbianchi.me → 10.0.20.200` non sono persistenti e, non venendo più riapplicati, spariranno al prossimo restart del pod — coerente con la scelta di non mantenere DNS split-horizon.

Verifica finale nel pool MetalLB:
```bash
kubectl -n metallb-system get ipaddresspools lan-pool -o yaml
# 10.0.20.202 torna disponibile per usi futuri
```

---

## Riepilogo file toccati in questo commit

Nuovi:
- `argo/applications/sealed-secrets.yaml`
- `argo/applications/cloudflared.yaml`, `argo/apps/cloudflared/{namespace,configmap,deployment}.yaml` (+ `sealedsecret-tunnel-credentials.yaml` generato da te in Fase 1.3)
- `argo/applications/authentik-secrets.yaml`, `argo/applications/authentik.yaml`, `argo/apps/authentik/namespace.yaml` (+ `sealedsecret-authentik-secrets.yaml` generato da te in Fase 3.1)

Modificati (whitelist → auth-* Authentik): `argo/apps/homepage/ingress.yaml`, `argo/apps/pihole/ingress.yaml`, `argo/apps/transmission/ingress.yaml`, `argo/apps/frigate/ingress.yaml`, `argo/apps/radarr/deployment.yaml`, `argo/apps/sonarr/deployment.yaml`, `argo/apps/prowlarr/deployment.yaml`, `argo/apps/bazarr/deployment.yaml`.

Modificati (whitelist rimosso, nessun auth-*): `argo/apps/argocd-ingress/ingress.yaml`, `argo/apps/immich/ingress.yaml`, `argo/apps/nextcloud/ingress.yaml`, `argo/apps/paperless/ingress.yaml`, `argo/apps/home-assistant/ingress.yaml`.

Modificato: `argo/apps/homepage/configmap.yaml` (nuovi tile + gruppi Cloud/Home, rimosso WireGuard).

Da rimuovere in Fase 7 (non ancora toccato): `argo/applications/wireguard.yaml`, `argo/apps/wireguard/`.

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
   - Salva.

   ⚠️ **Non aspettarti un nuovo pod o Service**: l'embedded outpost gira *dentro* il processo di `authentik-server` stesso, non viene creato nessun Deployment/Service separato (questo succede solo se assegni all'outpost una "Kubernetes Service Connection", che qui non serve). Verifica invece così:
   ```bash
   kubectl -n authentik get svc
   # atteso: solo authentik-server, authentik-postgresql, authentik-postgresql-hl — nessun "ak-outpost-*"
   ```

   4. **Imposta esplicitamente l'"Authentication flow"** sul Proxy Provider (non solo Authorization/Invalidation flow) — su questa versione del chart (2026.5.5), se lo lasci vuoto l'outpost va in **crash loop permanente** con un panic Go (`interface conversion: interface {} is nil, not string` in `application.go`) ogni volta che prova a ricostruire la sua configurazione interna. Usa `default-authentication-flow`.

   5. ⚠️ **Non fare mai `PATCH` parziali sulla config dell'outpost** (es. per cambiare solo `log_level`) tramite l'API — il campo `config` viene **sostituito per intero**, non fatto merge, e questo cancella silenziosamente `authentik_host` (causando lo stesso crash del punto 4). Se devi cambiare un valore di `config`, leggi prima l'oggetto completo e riscrivilo tutto.

   **Il vero punto critico — l'header Host della subrequest**: l'outpost registra le sue "Application" interne per hostname (log `"Loaded application","host":"auth.mbianchi.me"`) e usa l'header **Host** della richiesta di `auth_request` — non `X-Original-URL` — per decidere quale Application applicare. Puntare `auth-url` direttamente al Service interno (`authentik-server.authentik.svc.cluster.local`) fa sì che nginx invii quell'FQDN come Host, che non corrisponde a nessuna Application registrata → **404 persistente**, anche per l'host esatto del provider. La soluzione (già applicata in questo repo) è un rewrite DNS interno via CoreDNS così che `auth.mbianchi.me`, risolto DA DENTRO il cluster, punti direttamente al Service `authentik-server` — mantenendo così sia l'header Host corretto sia il routing tutto interno (nessun giro via Cloudflare Tunnel per un controllo che avviene ad ogni singola richiesta):

   `argo/infrastructure/coredns-custom/configmap.yaml` (letto automaticamente da k3s, nessuna modifica al Corefile principale):
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: coredns-custom
     namespace: kube-system
   data:
     mbianchi.override: |
       rewrite name auth.mbianchi.me authentik-server.authentik.svc.cluster.local
   ```
   Application: `argo/applications/coredns-custom.yaml`, sync-wave `-10` (deve esistere prima di tutto il resto).

   Verifica che il rewrite sia attivo (da un pod qualsiasi nel cluster):
   ```bash
   kubectl -n authentik exec deploy/authentik-worker -- getent hosts auth.mbianchi.me
   # atteso: l'IP ClusterIP di authentik-server (kubectl -n authentik get svc authentik-server), NON un IP pubblico
   ```

   Le annotazioni `auth-url` di questo repo usano quindi l'hostname pubblico (che grazie al rewrite risolve internamente):
   ```
   nginx.ingress.kubernetes.io/auth-url: "http://auth.mbianchi.me/outpost.goauthentik.io/auth/nginx"
   ```

   ⚠️ **Conseguenza del rewrite per qualunque client OIDC (Dex, Immich, Nextcloud, Paperless, ecc.)**: connettendosi direttamente al Service `authentik-server` sulla porta **443**, questi client trovano il certificato **self-signed interno** di Authentik (non quello Let's Encrypt, che nginx-ingress termina solo per il traffico che passa da lì) — falliscono con errori tipo `certificate is valid for *, not auth.mbianchi.me` (Dex) o `TypeError: fetch failed` (Immich/Node, che non ha un flag "skip verify" configurabile per-provider). La soluzione **generale e definitiva** — fatta una volta sola, vale per tutti i client futuri — è importare in Authentik il certificato Let's Encrypt reale (quello già emesso da cert-manager per l'Ingress di Authentik) e impostarlo come "Web Certificate" del Brand, così il listener HTTPS interno di `authentik-server` lo usa al posto del self-signed:
   ```bash
   CERT=$(kubectl -n authentik get secret authentik-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)
   KEY=$(kubectl -n authentik get secret authentik-tls -o jsonpath='{.data.tls\.key}' | base64 -d)
   kubectl -n authentik exec -i deploy/authentik-worker -- ak shell <<PYEOF
   from authentik.crypto.models import CertificateKeyPair
   from authentik.brands.models import Brand
   cert_pem = '''$CERT'''
   key_pem = '''$KEY'''
   ckp, _ = CertificateKeyPair.objects.update_or_create(
       name="auth.mbianchi.me (Let's Encrypt via cert-manager)",
       defaults=dict(certificate_data=cert_pem, key_data=key_pem)
   )
   brand = Brand.objects.get(domain='authentik-default')
   brand.web_certificate = ckp
   brand.save()
   PYEOF
   kubectl -n authentik rollout restart deployment authentik-server
   ```
   ⚠️ Il certificato Let's Encrypt di `authentik-tls` **si rinnova periodicamente** (cert-manager lo ruota prima della scadenza) — se in futuro torna l'errore di certificato su un nuovo client OIDC, rieseguire lo stesso comando per re-importare la versione aggiornata (questo passaggio andrebbe idealmente automatizzato con un piccolo CronJob o un Blueprint Authentik, non ancora fatto in questo repo).

   Verifica che funzioni:
   ```bash
   kubectl -n authentik exec deploy/authentik-worker -- curl -sv https://auth.mbianchi.me/application/o/argocd/.well-known/openid-configuration -o /dev/null 2>&1 | grep -i "certificate\|HTTP/"
   # atteso: nessun "self-signed certificate", HTTP/1.1 200 OK
   ```

### 3.5 Verifica il forward-auth

⚠️ **Se il tuo ingress-nginx ha gli snippet disabilitati** (verifica con `kubectl -n ingress-nginx get configmap ingress-nginx-controller -o jsonpath='{.data.allow-snippet-annotations}'` — se torna `false`, è il tuo caso), l'annotazione `auth-snippet` viene **rifiutata dall'admission webhook** e l'intero sync dell'Ingress fallisce, lasciando in produzione la vecchia configurazione (whitelist). Il sintomo è un **403 Forbidden** persistente anche dopo il push: il tunnel Cloudflare cambia l'IP sorgente visto da nginx, che con la vecchia whitelist ancora attiva nega l'accesso. Se ti càpita, controlla `kubectl get application <nome-app> -n argocd -o jsonpath='{.status.operationState.message}'` — se vedi "Snippet directives are disabled", è questo.

Non serve comunque: l'annotazione `auth-snippet` (che impostava `X-Forwarded-Host`) è ridondante — nginx-ingress imposta già di default `X-Original-URL` (con l'host originale incluso) sulla subrequest verso `auth-url`, che è quello che Authentik usa per ricostruire l'URL a cui reindirizzare dopo il login. I file di questo repo **non** includono più `auth-snippet` per questo motivo.

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
1. In Authentik: Provider **OAuth2/OpenID**, redirect URI `https://argo.mbianchi.me/api/dex/callback` (⚠️ **non** `/auth/callback` — quel path è per l'integrazione OIDC diretta senza Dex; qui usiamo `dex.config`, quindi il redirect passa dal callback di Dex), tipo client **confidential**, signing key = un certificato esistente (es. "authentik Self-signed Certificate" — Applications → Customization → Certificates, già presente di default), scope mapping `openid`/`profile`/`email`. ⚠️ **Verifica che "Grant Types" includa almeno `authorization_code`** (e tipicamente anche `refresh_token`) — se creato tramite un procedimento che salta il wizard normale questo campo può restare vuoto, causando l'errore Authentik "Invalid grant_type for provider" → Dex/ArgoCD vedono un generico "The request is otherwise malformed". Crea poi un'Application collegata (slug `argocd`). Annota **Client ID** e **Client Secret**.
   Nota: dopo il salvataggio, **riavvia sia `argocd-dex-server` sia `argocd-server`** (non solo Dex) — `argocd-server` deve ricaricare `argocd-cm` per esporre l'endpoint `/auth/login` che avvia il flusso SSO, altrimenti risponde 404.
2. Salva il client secret in `argocd-secret` (pattern standard di ArgoCD per non metterlo in chiaro nel ConfigMap):
   ```bash
   kubectl -n argocd patch secret argocd-secret --type merge \
     -p '{"stringData":{"dex.argocd.clientSecret":"<CLIENT_SECRET>"}}'
   ```
3. Modifica il ConfigMap `argocd-cm` (non è tracciato in questo repo — ArgoCD stesso è stato installato via Helm fuori da GitOps):
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
             clientSecret: $dex.argocd.clientSecret
             insecureEnableGroups: true
             scopes: ["profile", "email"]
   ```
   (Non serve `insecureSkipVerify` se hai già fatto il fix del certificato reale in Fase 3, punto critico sopra — se non l'hai ancora fatto, Dex fallirà con `certificate is valid for *, not auth.mbianchi.me`: vai prima a sistemare quello, è un fix valido per tutti i client OIDC, non solo ArgoCD.)
   ⚠️ **Non aggiungere `openid` alla lista `scopes`**: Dex lo richiede sempre automaticamente. Se lo includi anche tu, la scope string finale ha `openid` duplicato (`openid+openid+profile+email`) e Authentik rifiuta la richiesta con "The request is otherwise malformed".
4. Riavvia sia Dex sia il server ArgoCD (**entrambi**, non solo Dex — `argocd-server` deve ricaricare la ConfigMap per esporre `/auth/login`):
   ```bash
   kubectl -n argocd rollout restart deployment argocd-dex-server
   kubectl -n argocd rollout restart deployment argocd-server
   ```
5. Verifica: `argocd login argo.mbianchi.me --sso` dalla CLI e login da browser mostrano il pulsante "Log in via Authentik" (controllabile anche via `curl -sk https://argo.mbianchi.me/api/v1/settings | grep -A3 dexConfig`). Se il click sul pulsante rimanda a `/login?has_sso_error=true`, controlla i log di `authentik-server` (`kubectl -n authentik logs deploy/authentik-server --tail 20`) — l'errore più comune è `"Invalid grant_type for provider"`, che indica che il campo **Grant Types** del Provider non include `authorization_code`.
6. ⚠️ **Dopo il login SSO, ArgoCD mostra zero Applications finché non configuri l'RBAC** (`argocd-rbac-cm` di default nega tutto a chiunque non sia l'utente locale `admin`). Mappa il gruppo Authentik dell'utente (verificalo con `kubectl -n authentik exec deploy/authentik-worker -- ak shell -c "from authentik.core.models import User; [print(u.username, u.email, [g.name for g in u.groups.all()]) for u in User.objects.all()]"`) a un ruolo ArgoCD:
   ```bash
   kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p '{"data":{"policy.csv":"g, authentik Admins, role:admin","scopes":"[groups, email]"}}'
   ```
   Non serve riavviare nulla — `argocd-server` ricarica `argocd-rbac-cm` a caldo, basta un refresh della pagina (anche senza rifare login, il claim `groups` è già nel token di sessione esistente).

#### Immich
1. In Authentik: Provider OAuth2, redirect URI `https://immich.mbianchi.me/auth/login`, scope `openid profile email`.
2. In Immich: **Administration → Settings → OAuth**, abilita, incolla Issuer URL (`https://auth.mbianchi.me/application/o/immich/`), Client ID/Secret, salva.
3. Verifica login da web e da app mobile (pulsante "Login with OAuth").

#### Nextcloud
1. In Authentik: Provider OAuth2, redirect URI `https://nextcloud.mbianchi.me/apps/user_oidc/code`, grant types `authorization_code` + `refresh_token`.
2. In Nextcloud, via `occ` (più rapido della UI, nessun bisogno di loggarsi come admin da browser):
   ```bash
   kubectl -n nextcloud exec deploy/nextcloud -- php occ app:install user_oidc
   kubectl -n nextcloud exec deploy/nextcloud -- php occ user_oidc:provider Authentik \
     --clientid="<CLIENT_ID>" \
     --clientsecret="<CLIENT_SECRET>" \
     --discoveryuri="https://auth.mbianchi.me/application/o/nextcloud/.well-known/openid-configuration" \
     --scope="openid profile email" \
     --unique-uid=0 --check-bearer=0 --group-provisioning=0 --send-id-token-hint=1
   ```
3. Verifica: `kubectl -n nextcloud exec deploy/nextcloud -- php occ user_oidc:provider` deve elencare il provider "Authentik"; poi testa il login da browser su `https://nextcloud.mbianchi.me/login`. I client desktop/mobile di sync continuano a usare le app-password esistenti, non toccati.

#### Paperless-ngx
Le versioni recenti di Paperless-ngx (verificato su 2.20.x) supportano OIDC nativo via `django-allauth` — molto più pulito del vecchio approccio header-based, niente bisogno di `auth-snippet`/`auth-url` sull'ingress.

1. In Authentik: Provider OAuth2, redirect URI `https://paperless.mbianchi.me/accounts/oidc/authentik/login/callback/` (`oidc` è il prefisso di default di allauth per il provider generico `openid_connect`, `authentik` è il `provider_id` che scegli tu — deve combaciare esattamente in entrambi i posti), grant types `authorization_code` + `refresh_token`.
2. Crea un `SealedSecret` (`argo/apps/paperless/sealedsecret-oidc.yaml`) con la chiave `PAPERLESS_SOCIALACCOUNT_PROVIDERS` contenente questo JSON (sostituisci client_id/secret):
   ```bash
   PAYLOAD='{"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"<CLIENT_ID>","secret":"<CLIENT_SECRET>","settings":{"server_url":"https://auth.mbianchi.me/application/o/paperless/.well-known/openid-configuration","fetch_userinfo":true}}],"SCOPE":["openid","profile","email"]}}'
   kubectl create secret generic paperless-oidc --namespace paperless \
     --from-literal=PAPERLESS_SOCIALACCOUNT_PROVIDERS="$PAYLOAD" \
     --dry-run=client -o yaml \
   | kubeseal --controller-name sealed-secrets-controller --controller-namespace sealed-secrets --format yaml \
   > argo/apps/paperless/sealedsecret-oidc.yaml
   ```
3. Aggiungi al Deployment (`argo/apps/paperless/deployment.yaml`) due env var: `PAPERLESS_APPS: allauth.socialaccount.providers.openid_connect` e `PAPERLESS_SOCIALACCOUNT_PROVIDERS` da `secretKeyRef` sul secret appena creato.
4. Committa e pusha entrambi i file. Dopo il sync, verifica login da browser su `https://paperless.mbianchi.me`.
5. ⚠️ **Se hai già un utente admin locale esistente** (verificalo con `kubectl -n paperless exec deploy/paperless -- python3 /usr/src/paperless/src/manage.py shell -c "from django.contrib.auth.models import User; [print(u.pk,u.username,u.email) for u in User.objects.all()]"`), il primo login SSO creerà quasi certamente un **utente separato/duplicato** (a meno che l'email Authentik non combaci esattamente con quella già in Paperless). Per collegarli senza perdere permessi/documenti: fai un login di prova via SSO, poi ricollega il record `SocialAccount` creato all'utente esistente invece di lasciarlo sul nuovo duplicato:
   ```bash
   kubectl -n paperless exec deploy/paperless -- python3 /usr/src/paperless/src/manage.py shell -c "
   from allauth.socialaccount.models import SocialAccount
   from django.contrib.auth.models import User
   sa = SocialAccount.objects.latest('id')          # l'ultimo creato dal test login
   existing = User.objects.get(username='<utente-esistente>')
   duplicate = sa.user
   sa.user = existing
   sa.save()
   duplicate.delete()                                # sicuro solo se il duplicato non possiede documenti
   "
   ```

---

## Fase 4 — Home Assistant: niente Cloudflare Access, solo login nativo + 2FA

⚠️ **Cambio rispetto al piano originale**: l'app companion di Home Assistant (iOS/Android) **non supporta l'invio di header personalizzati** (`CF-Access-Client-Id`/`Secret`) — è un limite noto e ancora aperto della companion app, non qualcosa che si possa configurare lato app. Il Service Token di Cloudflare Access quindi non è utilizzabile dall'app nativa in nessun modo diretto (nessun campo "Configure Cloudflare Access" esiste nell'app, a differenza di quanto inizialmente ipotizzato in questo runbook).

Approccio adottato: **Home Assistant resta senza Cloudflare Access**, esattamente come Plex/ntfy — nessuna whitelist, nessun forward-auth, nessuna Access Application. L'unica protezione è il login nativo di Home Assistant, rinforzato con la **2FA (TOTP)**:

1. Se hai già creato un'Access Application per `homeassistant.mbianchi.me` in Cloudflare Zero Trust, **eliminala** (Zero Trust → Access → Applications → ⋮ → Delete) insieme al Service Token associato, ormai inutilizzabile.
2. Su Home Assistant (da browser, login con l'account esistente): **Profilo (icona in basso a sinistra) → Sicurezza → Multi-factor authentication → Abilita "Authenticator app da OTP"**, scansiona il QR code con un'app TOTP (Authy, Google Authenticator, Bitwarden, ecc.).
3. Verifica: da ora in poi il login su `https://homeassistant.mbianchi.me` richiede password + codice TOTP, sia da browser che dall'app companion.

Nota: non serve nessuna modifica alla VM Home Assistant stessa — `http.trusted_proxies` resta invariato, l'Ingress non ha annotazioni whitelist/auth-* (già rimosse in Fase 3.5).

Alternative più complesse non adottate (menzionate per completezza): un proxy locale come il progetto community "app-cloudflared" per gestire il Service Token lato client, oppure una policy Cloudflare Access con bypass per User-Agent (sconsigliato, facilmente falsificabile).

---

## Fase 5 — Verifica end-to-end (da fuori casa)

Disattiva il WiFi, usa la connessione dati del telefono (o un hotspot), e verifica:

```bash
curl -I https://mbianchi.me
curl -I https://home.mbianchi.me        # deve redirigere ad auth.mbianchi.me
curl -I https://plex.mbianchi.me        # pubblico, nessun redirect
curl -I https://ntfy.mbianchi.me        # pubblico, nessun redirect
curl -I https://homeassistant.mbianchi.me   # pubblico, nessun redirect — protetto solo da login nativo HA + 2FA
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

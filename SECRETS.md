# Configuration des secrets (clés API, webhooks)

Les clés et webhooks **ne doivent jamais** être dans le code source. Ils sont lus via **Firebase Functions Config**.

## 1. Configurer les secrets

Exécute ces commandes (une seule fois, ou pour mettre à jour) à la racine du projet :

```bash
firebase functions:config:set brevo.api_key="xkeysib-TA_CLE_BREVO"
firebase functions:config:set discord.reports_webhook="https://discord.com/api/webhooks/..."
firebase functions:config:set discord.bans_webhook="https://discord.com/api/webhooks/..."
firebase functions:config:set discord.bugs_webhook="https://discord.com/api/webhooks/..."
```

Remplace les valeurs par tes vrais secrets.

## 2. Vérifier la config

```bash
firebase functions:config:get
```

## 3. Redéployer les functions

Après avoir configuré :

```bash
cd functions
npm run build
firebase deploy --only functions
```

## 4. Récapitulatif

| Config | Rôle |
|--------|------|
| `brevo.api_key` | Clé API Brevo (emails de vérification) |
| `discord.reports_webhook` | Webhook Discord pour les reports |
| `discord.bans_webhook` | Webhook Discord pour les bans/unbans |
| `discord.bugs_webhook` | Webhook Discord pour les bugs signalés |

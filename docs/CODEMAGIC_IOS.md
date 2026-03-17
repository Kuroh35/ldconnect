# Build iOS sur Codemagic

## Erreur `generated_plugin_registrant.rb` introuvable

Cette erreur apparaît quand **pod install** est exécuté **avant** que Flutter n’ait généré le fichier `ios/Flutter/generated_plugin_registrant.rb`.

### À faire dans Codemagic

1. **Ne jamais lancer `pod install` (ou `cd ios && pod install`) à part.**  
   Seul `flutter build ios` doit déclencher CocoaPods. Si tu as une étape “Run pod install” ou un script qui fait `pod install`, supprime-la.

2. **Ordre des commandes pour l’iOS :**
   ```bash
   flutter pub get
   flutter build ios --release --no-codesign
   ```
   Ne pas ajouter d’étape “pod install” entre les deux ou après.

3. **Répertoire de travail :** le build doit être lancé à la **racine du projet** (dossier qui contient `pubspec.yaml`), pas dans `ios/` ou un sous-dossier. Dans Codemagic, vérifier que le “Working directory” (ou l’équivalent) est bien cette racine.

4. **Utiliser le `codemagic.yaml` du repo** (à la racine) : il est déjà configuré avec le bon enchaînement. Dans l’app Codemagic, il faut que le workflow utilise ce fichier (ou reprendre les mêmes étapes dans l’éditeur de workflow).

Après ça, le build iOS ne devrait plus échouer sur `generated_plugin_registrant.rb`.

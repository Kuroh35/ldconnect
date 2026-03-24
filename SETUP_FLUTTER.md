# Configuration Flutter & Android Studio - ld_connect

## ✅ Ce qui a été installé

1. **Android Studio** (2025.3.1.8) - avec SDK Android, émulateur, etc.
2. **Git** (2.53.0)
3. **Flutter SDK** (3.41.5) - installé dans `C:\src\flutter`
4. **Flutter ajouté au PATH** - vous pouvez lancer `flutter` dans un nouveau terminal

## 📋 Dernières étapes à faire manuellement

### 1. Fermer et rouvrir votre terminal
Pour que Flutter soit reconnu, **ouvrez un nouveau terminal** (PowerShell ou CMD).

### 2. Installer les Android Command-line Tools via Android Studio

1. Lancez **Android Studio** (menu Démarrer)
2. Si c'est la première ouverture, suivez l'Assistant de configuration
3. Allez dans **Outils (Tools)** → **SDK Manager** (ou **File** → **Settings** → **Appearance & Behavior** → **System Settings** → **Android SDK**)
4. Onglet **SDK Tools**
5. Cochez **Android SDK Command-line Tools (latest)**
6. Cliquez sur **Apply** puis **OK**

### 3. Accepter les licences Android

Dans un **nouveau terminal** :
```powershell
flutter doctor --android-licenses
```
Tapez `y` pour accepter chaque licence.

### 4. Installer le plugin Flutter dans Android Studio

1. Dans Android Studio : **File** → **Settings** → **Plugins**
2. Recherchez **Flutter** et installez-le (il installera aussi **Dart** automatiquement)
3. Redémarrez Android Studio si demandé

### 5. Lancer votre app

```powershell
cd c:\Users\spoti\Desktop\bot\ld_connect
flutter pub get
flutter run
```

Ou ouvrez le dossier `ld_connect` dans Android Studio et lancez avec le bouton Run (▶️).

## 🔧 Vérifier l'installation

```powershell
flutter doctor -v
```

Tous les crochets devraient être verts ✓ pour Android après les étapes ci-dessus.

## 📱 Test sur émulateur ou appareil

- **Émulateur** : Dans Android Studio, **Tools** → **Device Manager** → Créez un AVD (émulateur) si besoin
- **Appareil physique** : Activez le **mode développeur** et le **débogage USB** sur votre téléphone

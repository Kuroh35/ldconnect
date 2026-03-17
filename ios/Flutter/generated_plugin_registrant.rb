# Ce fichier permet à CocoaPods de charger le podhelper Flutter (définit flutter_install_all_ios_pods, etc.).
# En CI (ex. Codemagic), Flutter ne le génère pas toujours avant pod install ; on le versionne pour débloquer le build.
flutter_root = ENV['FLUTTER_ROOT']
if flutter_root.nil? || flutter_root.empty?
  # Fallback: chemin relatif depuis ios/Flutter vers la racine du repo, puis vers le Flutter SDK si à côté
  project_root = File.expand_path(File.join(File.dirname(File.realpath(__FILE__)), '..', '..'))
  flutter_root = File.join(project_root, 'flutter')
  flutter_root = nil unless Dir.exist?(flutter_root)
end
raise "FLUTTER_ROOT non défini et Flutter introuvable. Définis FLUTTER_ROOT ou exécute depuis un environnement Flutter (ex. Codemagic)." unless flutter_root && Dir.exist?(flutter_root)

podhelper_path = File.join(flutter_root, 'packages', 'flutter_tools', 'bin', 'podhelper.rb')
raise "podhelper.rb introuvable: #{podhelper_path}" unless File.exist?(podhelper_path)

load File.expand_path(podhelper_path)

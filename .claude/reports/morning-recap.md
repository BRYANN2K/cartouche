# Récap de la nuit (2026-10-21)

Fusionné dans main (rien n'est poussé, sauf la release cartouche-wine) :
- Nouvelle interface Liquid Glass + fenêtre unique « Add Games »
- 5 travaux Devin : couvertures de secours, reconnaissance du nom, composants par jeu, désinstallation, Steam fermé
- Export de la bibliothèque Steam (dylib, route protégée par jeton)
- Installation directe des installeurs à décompresseur externe (unarc-driver)
- CrossOver 26.3 par défaut + étape « Preparing Windows environment » + vraies raisons D3DMetal/DXMT
- Décompresseur libarchive 3.8.9 (zip, 7z, tar, RAR4/RAR5 multi-parties et solides) + détection (pas encore branchée sur Add Games)
- Interface de vérification (moteur à venir)
- Correction du plantage (plus d'lsof/pgrep pendant le dessin) + correction Sparkle

App : out/Cartouche.app compilée à 02:15. Lancée 2 min 30 sans plantage ni erreur Sparkle.
Tests complets sur main : voir .claude/reports/main-tests-summary.txt

À faire ensuite :
1. Test Lost in Random (Add Games) + mesure de vitesse
2. Installer Wine CrossOver (Réglages > Runners) puis tester D3DMetal
3. Vérifier la bibliothèque Steam complète (export)
4. Relancer les 4 tâches Devin (briefs dans .claude/briefs/) : téléchargements Steam, comparaison perfs, désinstallation consoles, lancement Mac
5. Devin : brancher le décompresseur sur Add Games ; moteur de vérification + repli
6. Tes actions pour la 0.1.0 : .claude/reports/release-tasks-maintainer.md

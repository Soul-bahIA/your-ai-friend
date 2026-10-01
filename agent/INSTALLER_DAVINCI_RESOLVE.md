# Montage professionnel avec DaVinci Resolve — Installation & configuration

L'agent SoulBah peut piloter **DaVinci Resolve** (installé sur ton PC) pour faire un
vrai montage professionnel en local et exporter la vidéo — via l'API de script de Resolve,
sans passer par une API cloud pour le montage.

Suis ces 4 étapes **une seule fois** :

## 1. Installer DaVinci Resolve (gratuit)
- Télécharge la version gratuite : https://www.blackmagicdesign.com/products/davinciresolve
- Installe-la (compte ~3 Go). La version gratuite suffit pour le montage et l'export MP4.

## 2. Lancer Resolve au moins une fois
Ouvre DaVinci Resolve une première fois (ça crée les fichiers de configuration).

## 3. Activer le scripting externe
Dans Resolve :
- Menu **DaVinci Resolve → Preferences** (ou `Ctrl+,`)
- Onglet **System → General**
- **"External scripting using"** → choisis **Local**
- Clique **Save** et redémarre Resolve.

## 4. Laisser Resolve OUVERT pendant l'usage
Quand tu demandes un montage professionnel à l'agent, **DaVinci Resolve doit être ouvert** :
l'agent s'y connecte, importe les médias, monte la timeline et exporte.

---

## Vérifier que tout est bon
Une fois installé et configuré, l'agent (dans la page Automatisation) pourra exécuter un
objectif du type :

> « Enregistre une démo de 10 secondes de mon écran, monte-la dans DaVinci Resolve et
>   exporte le résultat en MP4 dans le dossier du projet. »

Le plan généré ouvrira Resolve, fera le montage et exportera — le tout sur ton PC.

## Emplacements attendus (Windows, par défaut)
- Bibliothèque : `C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll`
- Modules de script : `C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting\Modules`

Si Resolve est installé ailleurs, définis les variables d'environnement
`RESOLVE_SCRIPT_LIB` et `RESOLVE_SCRIPT_API` en conséquence.

> ⚠️ Cette intégration n'a pas encore pu être testée sur une machine avec Resolve installé.
> Après ton installation, on la validera ensemble et on ajustera si l'API de ta version de
> Resolve diffère.

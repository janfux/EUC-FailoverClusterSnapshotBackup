# MS Failover Cluster snapshot backup

Skript til at tage snapshot af alle vms på et cluster og kopiere dem til en netværksshare som en disaster recovery backup.

WORK IN PROGRESS / ARCHIVED

Meningen er at køre det some en cluster scheduled task, dvs clusteret kører det på bestemte tidspunkter på en af noderne, der lige har ressourcer til det.

Det skaber det problem, at hvis en vm fx lige ligger på node1, men skriptet køres på node2, så eksekveres kommandoer som "export-vmsnapshot" automatisk gennem powershell remoting. En remote session på node 1 har dog svært ved at tilgå netværksshare på vegne af et skript der kører på node2. Det er kendt som "double-hop" problemet og fører til, at eksporten slår fejl for vms, der ikke ligger på samme node som den, der kører skriptet.

Nuværende version løser "douple hop" problemet ved at kopiere det eksporterede snapshot fra den lokale disk til netværksdrevet "igennem" en powershell session til den host, hvor vm ligger. Det er bare utrolig langsomt.

Der skal findes en bedre løsning, ellers er det ikke brugbart.

En ide kunne være at dele det op i to - et skript, der køres på hver node lokalt og laver eksporten, og et skript, der kalder de lokale skripts på noderne og styrer dem, som kører som task.

Styringsskriptet kunne indeholde krypterede credentials til en service account, der må tilgå backup share og som sendes videre til noderne gemmen credssp.

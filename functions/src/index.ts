import * as functions from "firebase-functions/v1";
import * as admin from "firebase-admin";
import * as dotenv from "dotenv";

dotenv.config();
admin.initializeApp();

export const sendUserNotification = functions.firestore
  .document("users/{userId}/notifications/{notifId}")
  .onCreate(async (
    snap: functions.firestore.QueryDocumentSnapshot,
    context: functions.EventContext,
  ) => {
    const userId = context.params.userId as string;
    const data = snap.data() as any;

    const type = (data.type as string) || "";
    const message = (data.message as string) || "";
    const fromUserId = (data.fromUserId as string | undefined) || "";

    let fromUserName = (data.fromUserName as string | undefined) || "";
    if (fromUserId && !fromUserName) {
      const fromUserDoc = await admin
        .firestore()
        .collection("users")
        .doc(fromUserId)
        .get();
      const fromData = fromUserDoc.data() || {};
      fromUserName =
        (fromData.pseudo as string | undefined) ||
        (fromData.email as string | undefined) ||
        "Quelqu'un";
    }

    // Récupère les tokens FCM du destinataire
    const userDoc = await admin.firestore().collection("users").doc(userId).get();
    const tokens = (userDoc.data()?.fcmTokens as string[] | undefined) ?? [];
    if (!tokens.length) {
      console.log("No FCM tokens for user", userId);
      return;
    }

    // Construire un titre / body en fonction du type
    let title = "LD Connect";
    let body = message || "Nouvelle activité sur ton compte.";

    switch (type) {
      case "follow":
        title = "Nouveau follower";
        if (!message) body = `${fromUserName} te suit maintenant.`;
        break;
      case "friend_request":
        title = "Nouvelle demande d'ami";
        if (!message) body = `${fromUserName} t'a envoyé une demande d'ami.`;
        break;
      case "friend_accept":
        title = "Nouvel ami";
        if (!message) body = `${fromUserName} a accepté ta demande d'ami.`;
        break;
      case "follow_post":
        title = "Nouveau post";
        if (!message) body = "Un joueur que tu suis a publié un post.";
        break;
      case "comment":
        title = "Nouveau commentaire";
        if (!message) body = `${fromUserName} a commenté ton post.`;
        break;
      case "like":
      case "comment_like":
        title = "Nouveau like";
        if (!message) body = `${fromUserName} a liké ton contenu.`;
        break;
      case "mention_post":
      case "mention_comment":
        title = "Tu as été mentionné";
        if (!message) body = `${fromUserName} t'a mentionné.`;
        break;
      default:
        title = "Notification";
    }

    const payload: admin.messaging.MulticastMessage = {
      tokens,
      notification: {
        title,
        body,
      },
      android: {
        notification: {
          icon: "ic_launcher",
        },
      },
      data: {
        type,
        postId: (data.postId as string | undefined) ?? "",
        commentId: (data.commentId as string | undefined) ?? "",
        fromUserId,
      },
    };

    await admin.messaging().sendEachForMulticast(payload);
  });

export const sendVerificationEmail = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Non authentifié.");
  }
  const email = data?.email as string | undefined;
  const code = data?.code as string | undefined;
  if (!email || !code) {
    throw new functions.https.HttpsError("invalid-argument", "email et code requis");
  }
  // Priorité :
  // 1) .env / variables d'environnement (local)
  // 2) firebase functions:config:set brevo.api_key="..." (prod)
  const apiKey =
    process.env.BREVO_API_KEY ||
    ((functions as any).config?.()?.brevo?.api_key as string | undefined);
  if (!apiKey) {
    throw new functions.https.HttpsError("failed-precondition", "Brevo non configuré");
  }
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json" },
    body: JSON.stringify({
      sender: { name: "LD Connect", email: "leader.driveld@gmail.com" },
      to: [{ email }],
      subject: `Ton code LD Connect : ${code}`,
      htmlContent: `<h1>Bienvenue !</h1><p>Voici ton code de validation : <b>${code}</b></p>`,
    }),
  });
  if (!res.ok) {
    const text = await res.text();
    console.error("Brevo API error:", res.status, text);
    throw new functions.https.HttpsError("internal", "Erreur envoi email");
  }
  return { ok: true };
});

function normalizeVerificationCode(
  raw: string | number | undefined | null,
): string {
  if (raw === undefined || raw === null) return "";
  return String(raw).replace(/\D/g, "");
}

export const verifyEmailCode = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Non authentifié.");
  }
  const code = normalizeVerificationCode(data?.code as string | undefined);
  if (!code) {
    throw new functions.https.HttpsError("invalid-argument", "code requis");
  }

  const uid = context.auth.uid;
  const userRef = admin.firestore().collection("users").doc(uid);
  const snap = await userRef.get();
  if (!snap.exists) {
    throw new functions.https.HttpsError("not-found", "Profil introuvable");
  }
  const u = snap.data() as any;
  const stored = normalizeVerificationCode(u?.verificationCode);
  if (!stored || stored !== code) {
    throw new functions.https.HttpsError("permission-denied", "Code incorrect");
  }

  await Promise.all([
    userRef.update({
      isVerified: true,
      verificationCode: admin.firestore.FieldValue.delete(),
    }),
    admin.auth().updateUser(uid, { emailVerified: true }),
  ]);

  return { ok: true };
});

// Les signalements sont consultés dans l’app (Menu admin → Signalements).
export const onReportCreated = functions.firestore
  .document("reports/{reportId}")
  .onCreate(async () => {
    return;
  });

export const onBanCreated = functions.firestore
  .document("bans/{banId}")
  .onCreate(async (snap, context) => {
    const data = snap.data() as any;

    let webhookUrl: string | undefined;
    try {
      const config = (functions as any).config?.() ?? {};
      webhookUrl = config.discord?.bans_webhook as string | undefined;
    } catch {
      webhookUrl = undefined;
    }
    if (!webhookUrl) {
      console.warn("Missing discord.bans_webhook config");
      return;
    }

    const userId = (data.userId as string | undefined) ?? "Inconnu";
    const moderatorId = (data.moderatorId as string | undefined) ?? "Inconnu";
    let userLabel = userId;
    let moderatorLabel = moderatorId;

    try {
      if (userId && userId !== "Inconnu") {
        const userSnap = await admin.firestore().collection("users").doc(userId).get();
        const uData = userSnap.data() as any | undefined;
        const pseudo = (uData?.pseudo as string | undefined) ?? (uData?.email as string | undefined);
        if (pseudo) {
          userLabel = `${pseudo} (${userId})`;
        }
      }
      if (moderatorId && moderatorId !== "Inconnu") {
        const modSnap = await admin.firestore().collection("users").doc(moderatorId).get();
        const mData = modSnap.data() as any | undefined;
        const pseudo =
          (mData?.pseudo as string | undefined) ?? (mData?.email as string | undefined);
        if (pseudo) {
          moderatorLabel = `${pseudo} (${moderatorId})`;
        }
      }
    } catch (e) {
      console.warn("Failed to enrich ban usernames:", e);
    }
    const permanent = (data.permanent as boolean | undefined) ?? false;

    let untilText = "Non spécifiée";
    try {
      const banUntil = (data.banUntil as admin.firestore.Timestamp | undefined)
        ?.toDate?.();
      if (banUntil) {
        untilText = banUntil.toISOString();
      }
    } catch {
      // ignore parsing errors
    }

    const createdAtDate =
      (data.createdAt as admin.firestore.Timestamp | undefined)?.toDate?.() ??
      new Date();

    const typeLabel = permanent
      ? "Ban permanent"
      : untilText !== "Non spécifiée"
      ? `Ban temporaire jusqu'à ${untilText}`
      : "Ban temporaire";

    const fields: any[] = [
      { name: "Utilisateur banni", value: userLabel, inline: true },
      { name: "Modérateur", value: moderatorLabel, inline: true },
      { name: "Type", value: typeLabel, inline: false },
    ];

    const payload = {
      username: "LD Connect – Modération",
      embeds: [
        {
          title: "Nouveau bannissement",
          color: 0xff0000,
          fields,
          timestamp: createdAtDate.toISOString(),
        },
      ],
    };

    try {
      const res = await fetch(webhookUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (!res.ok) {
        const text = await res.text();
        console.error("Discord bans webhook failed:", res.status, text);
      }
    } catch (e) {
      console.error("Discord bans webhook error:", e);
    }
  });

export const onBanUpdated = functions.firestore
  .document("bans/{banId}")
  .onUpdate(async (change, context) => {
    const before = change.before.data() as any;
    const after = change.after.data() as any;

    const beforeActive = (before.active as boolean | undefined) ?? true;
    const afterActive = (after.active as boolean | undefined) ?? true;

    // On ne log que les transitions actif -> inactif (unban)
    if (beforeActive && !afterActive) {
      let webhookUrl: string | undefined;
      try {
        const config = (functions as any).config?.() ?? {};
        webhookUrl = config.discord?.bans_webhook as string | undefined;
      } catch {
        webhookUrl = undefined;
      }
      if (!webhookUrl) {
        console.warn("Missing discord.bans_webhook config for unban");
        return;
      }

      const userId = (after.userId as string | undefined) ?? "Inconnu";
      const moderatorId =
        (after.unbannedBy as string | undefined) ??
        (after.moderatorId as string | undefined) ??
        "Inconnu";

      let userLabel = userId;
      let moderatorLabel = moderatorId;

      try {
        if (userId && userId !== "Inconnu") {
          const userSnap = await admin.firestore().collection("users").doc(userId).get();
          const uData = userSnap.data() as any | undefined;
          const pseudo =
            (uData?.pseudo as string | undefined) ??
            (uData?.email as string | undefined);
          if (pseudo) {
            userLabel = `${pseudo} (${userId})`;
          }
        }
        if (moderatorId && moderatorId !== "Inconnu") {
          const modSnap = await admin.firestore().collection("users").doc(moderatorId).get();
          const mData = modSnap.data() as any | undefined;
          const pseudo =
            (mData?.pseudo as string | undefined) ??
            (mData?.email as string | undefined);
          if (pseudo) {
            moderatorLabel = `${pseudo} (${moderatorId})`;
          }
        }
      } catch (e) {
        console.warn("Failed to enrich unban usernames:", e);
      }

      const unbannedAtDate =
        (after.unbannedAt as admin.firestore.Timestamp | undefined)
          ?.toDate?.() ?? new Date();

      const fields: any[] = [
        { name: "Utilisateur débanni", value: userLabel, inline: true },
        { name: "Modérateur", value: moderatorLabel, inline: true },
      ];

      const payload = {
        username: "LD Connect – Modération",
        embeds: [
          {
            title: "Ban levé",
            color: 0x00ff00,
            fields,
            timestamp: unbannedAtDate.toISOString(),
          },
        ],
      };

      try {
        const res = await fetch(webhookUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        if (!res.ok) {
          const text = await res.text();
          console.error("Discord unban webhook failed:", res.status, text);
        }
      } catch (e) {
        console.error("Discord unban webhook error:", e);
      }
    }
  });

// Les bugs sont consultés dans l’app (Menu admin → Bugs signalés).
export const onBugReportCreated = functions.firestore
  .document("bug_reports/{bugId}")
  .onCreate(async () => {
    return;
  });


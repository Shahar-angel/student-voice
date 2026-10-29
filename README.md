# קול הסטודנטים

![בדיקות](https://github.com/Shahar-angel/student-voice/actions/workflows/tests.yml/badge.svg)

הקוד נפרס ל-Google אוטומטית מ-`main` (`tools/deploy-google.ps1`, ראו [התקנה ופריסה](docs/01-התקנה-ופריסה.md)).

צ'אט משוב לסטודנטים, עם לוח לניהול לכל קורס. סטודנטים כותבים טענות והערות על כל חלק של הקורס, ו-Claude מרכז אותן לפניות, מסווג לפי תחום ומפיק המלצות לשיפור. ההנהלה עונה לכל פנייה, והסטודנט רואה את הסטטוס ואת המענה.

## קישורים
**הכי נוח:** לפתוח את הקובץ [קישורים.html](קישורים.html). יש בו כפתור פתיחה וקישור להעתקה לכל דף.

<!-- links:start -->
- **דף המנהל:** https://script.google.com/macros/s/AKfycbwNMlLD7f-VUwJ7ZcpXeCd6kjFZYGZUcAl59g17II3ANrEixq7mhImXVDpPDSBoSTHZnQ/exec
- **דף הסטודנטים (לכל הקורסים):** https://script.google.com/macros/s/AKfycbwNMlLD7f-VUwJ7ZcpXeCd6kjFZYGZUcAl59g17II3ANrEixq7mhImXVDpPDSBoSTHZnQ/exec?view=student
- **דף הנהלת הקורס (לכל הקורסים):** https://script.google.com/macros/s/AKfycbwNMlLD7f-VUwJ7ZcpXeCd6kjFZYGZUcAl59g17II3ANrEixq7mhImXVDpPDSBoSTHZnQ/exec?view=staff
- **קוד המערכת ב-Google (Apps Script):** https://script.google.com/u/1/home/projects/15RZeUDEYP16DrAyxhTUL_8O5YPcR96nJHlZX-rBQ3EUfv8oWBjnNYqpq/edit
<!-- links:end -->

את הקישורים כדאי לפתוח בחלון גלישה בסתר, כי הדפדפן מחובר לכמה חשבונות גוגל. הקישורים נבנים אוטומטית מ-`config/deployment.json`, ולא משתנים כשמוסיפים או מוחקים קורסים.

**מיילים:** מיילים שאנשי הנהלה שולחים לסטודנטים יוצאים מה-Gmail שלהם, דרך "שולח המיילים האישי", ולא מהחשבון של מנהל המערכת. ראו [מה השתנה](עדכון-שליחה-מהמייל-האישי/מה-השתנה.md) ו[איפיון המערכת](docs/00-איפיון-המערכת.md).

## GitHub
הפרויקט נמצא במאגר ציבורי: https://github.com/Shahar-angel/student-voice

**שיטת עבודה:** כל יכולת חדשה מפותחת בענף (branch) חדש משלה, לא ישירות ב-`main`. המערכת החיה ב-Google נפרסת רק מ-`main`, אחרי שהבדיקות עברו ואושר המיזוג. פירוט: [התקנה ופריסה](docs/01-התקנה-ופריסה.md), "עבודה עם GitHub".

**שמירה אוטומטית:** בסוף כל תור של Claude ה-hook `.claude/hooks/on-stop.ps1` שומר את כל השינויים ב-Git ודוחף את הענף הנוכחי ל-GitHub. ב-`main` נשמר רק `יומן-פעולות/`.

## קבצים
| | |
|---|---|
| `קישורים.html` | דף הקישורים: מנהל, סטודנט, הנהלת קורס, וקוד המערכת ב-Google. נוצר אוטומטית, לא לערוך |
| `config/deployment.json` | הכתובות והפרויקטים ב-Google: המערכת והשולח האישי |
| `tools/build-links.ps1` | בונה את דף הקישורים. ה-hook מריץ אותו |
| `tools/backup.ps1`, `tools/restore-backup.ps1` | גיבוי הפרויקט ושחזור גרסה. ה-hook מריץ את הגיבוי אחרי כל שינוי |
| `apps-script/` | **בדיוק מה שנמצא בפרויקט ב-Google.** `Code.gs` הוא צד השרת. `Index.html` הוא הממשק, ובפרויקט הוא נקרא `Index` |
| `apps-script-sender/` | **שולח המיילים האישי:** פרויקט Google נפרד, שרץ בחשבון של איש ההנהלה ושולח מה-Gmail שלו. `Code.gs` ו-`appsscript.json` |
| `backups/` | גיבוי מלא של הפרויקט אחרי כל שינוי, ו-`גרסאות.md` עם הרשימה. חוזרים לגרסה עם `tools\restore-backup.ps1`. **מקומי בלבד, לא ב-GitHub.** ההיסטוריה ב-Git היא הדרך העיקרית לחזור לגרסה קודמת |
| `.gitignore` | קבצים שלא עולים ל-GitHub, ובהם `backups/` |
| `עדכון-שליחה-מהמייל-האישי/` | דף הסבר: מה השתנה בעדכון השולח האישי, ואיך חוזרים לגרסה הקודמת |
| `יומן-פעולות/` | זיכרון משני של הפרויקט: רשומה לכל משימה (`רשומות/*.json`) ודף `index.html` שנבנה מהן אוטומטית. ציבורי, בלי מידע אישי. נבנה על ידי `tools/build-activity-log.ps1` |
| `docs/` | המדריכים |
| `tests/` | הבדיקות. מריצים עם `tests\run-tests.ps1`. התוצאה האחרונה נשמרת ב-`tests/last-results.md` |
| `CLAUDE.md` | כללי עבודה ל-Claude Code בפרויקט |
| `.claude/` | ה-hook שמעדכן את המסמכים ומריץ בדיקות |

## מדריכים
<!-- docs-index:start -->
- [איפיון המערכת: קול הסטודנטים](docs/00-איפיון-המערכת.md) · עודכן 2026-10-28 16:35
- [התקנה ופריסה](docs/01-התקנה-ופריסה.md) · עודכן 2026-10-29 09:14
- [מפתח Claude](docs/02-מפתח-Claude.md) · עודכן 2026-10-26 18:43
- [תפקידים, שיתוף ואיך רואים כל צד](docs/03-תפקידים-וצפייה.md) · עודכן 2026-10-27 16:57
- [בדיקות ואבטחה](docs/04-בדיקות-ואבטחה.md) · עודכן 2026-10-29 09:15
- [אפליקציה או קישור?](docs/05-אפליקציה-בטלפון.md) · עודכן 2026-10-26 19:08
- [יומן שינויים](docs/שינויים.md) · עודכן 2026-10-29 09:42

**בדיקות אחרונות:** הורץ: 2026-10-29 09:42  ·  עברו: 219  ·  נכשלו: 0 ([פירוט](tests/last-results.md))
<!-- docs-index:end -->

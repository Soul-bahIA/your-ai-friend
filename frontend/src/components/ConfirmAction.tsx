import { ReactNode } from "react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { buttonVariants } from "@/components/ui/button";

interface ConfirmActionProps {
  /** Élément déclencheur (bouton). Doit accepter une ref (asChild). */
  trigger: ReactNode;
  title: string;
  description?: ReactNode;
  confirmLabel?: string;
  onConfirm: () => void | Promise<void>;
}

/** Confirmation avant une action destructive (suppression...). */
const ConfirmAction = ({
  trigger,
  title,
  description = "Cette action est irréversible.",
  confirmLabel = "Supprimer",
  onConfirm,
}: ConfirmActionProps) => (
  // Les évènements React remontent à travers les portails : on les arrête ici pour que
  // les clics dans la boîte de dialogue n'activent pas la ligne/carte parente.
  <span className="contents" onClick={(e) => e.stopPropagation()}>
  <AlertDialog>
    <AlertDialogTrigger asChild>{trigger}</AlertDialogTrigger>
    <AlertDialogContent>
      <AlertDialogHeader>
        <AlertDialogTitle>{title}</AlertDialogTitle>
        <AlertDialogDescription>{description}</AlertDialogDescription>
      </AlertDialogHeader>
      <AlertDialogFooter>
        <AlertDialogCancel>Annuler</AlertDialogCancel>
        <AlertDialogAction
          className={buttonVariants({ variant: "destructive" })}
          onClick={() => {
            void onConfirm();
          }}
        >
          {confirmLabel}
        </AlertDialogAction>
      </AlertDialogFooter>
    </AlertDialogContent>
  </AlertDialog>
  </span>
);

export default ConfirmAction;

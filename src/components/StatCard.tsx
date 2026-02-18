interface StatCardProps {
  label: string;
  value: string;
  change?: string;
  positive?: boolean;
  delay?: number;
}

const StatCard = ({ label, value, change, positive = true, delay = 0 }: StatCardProps) => {
  return (
    <div
      className="rounded-lg border border-border bg-card p-5 opacity-0 animate-fade-in"
      style={{ animationDelay: `${delay}ms` }}
    >
      <p className="text-xs text-muted-foreground uppercase tracking-wider mb-2">{label}</p>
      <p className="text-2xl font-bold text-foreground font-mono">{value}</p>
      {change && (
        <p className={`text-xs mt-1 font-mono ${positive ? "text-success" : "text-destructive"}`}>
          {positive ? "↑" : "↓"} {change}
        </p>
      )}
    </div>
  );
};

export default StatCard;

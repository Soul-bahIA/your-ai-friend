import { useEffect, useState } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { useDatabase, Column, UserSchema } from "@/hooks/useDatabase";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Checkbox } from "@/components/ui/checkbox";
import { useToast } from "@/hooks/use-toast";
import {
  Database, Plus, Trash2, Edit, Save, ArrowLeft, History, Table2, Rows3, AlertTriangle, Loader2,
} from "lucide-react";

const COLUMN_TYPES = [
  { value: "text", label: "Texte" },
  { value: "number", label: "Nombre" },
  { value: "boolean", label: "Booléen" },
  { value: "date", label: "Date" },
  { value: "json", label: "JSON" },
] as const;

export default function DatabaseAdmin() {
  const db = useDatabase();
  const { toast } = useToast();
  const [activeSchema, setActiveSchema] = useState<UserSchema | null>(null);
  const [tab, setTab] = useState("tables");

  // Create table dialog
  const [showCreate, setShowCreate] = useState(false);
  const [newTableName, setNewTableName] = useState("");
  const [newTableDesc, setNewTableDesc] = useState("");
  const [newColumns, setNewColumns] = useState<Column[]>([
    { name: "id", type: "text", required: true },
  ]);

  // Edit column dialog
  const [editingSchema, setEditingSchema] = useState<UserSchema | null>(null);
  const [editColumns, setEditColumns] = useState<Column[]>([]);

  // Insert row dialog
  const [showInsert, setShowInsert] = useState(false);
  const [newRowData, setNewRowData] = useState<Record<string, string>>({});

  // Selected rows
  const [selectedRows, setSelectedRows] = useState<Set<string>>(new Set());

  useEffect(() => {
    db.loadSchemas();
  }, []);

  useEffect(() => {
    if (activeSchema) {
      db.loadData(activeSchema.id);
      db.loadMigrations(activeSchema.id);
    }
  }, [activeSchema]);

  const handleCreateTable = async () => {
    if (!newTableName.trim()) return;
    try {
      await db.createSchema(newTableName.trim(), newColumns, newTableDesc);
      setShowCreate(false);
      setNewTableName("");
      setNewTableDesc("");
      setNewColumns([{ name: "id", type: "text", required: true }]);
    } catch (e: any) {
      toast({ title: "Erreur", description: e.message, variant: "destructive" });
    }
  };

  const handleUpdateColumns = async () => {
    if (!editingSchema) return;
    try {
      const updated = await db.updateSchema(editingSchema.id, { columns: editColumns });
      setEditingSchema(null);
      if (activeSchema?.id === updated.id) setActiveSchema(updated);
    } catch (e: any) {
      toast({ title: "Erreur", description: e.message, variant: "destructive" });
    }
  };

  const handleInsertRow = async () => {
    if (!activeSchema) return;
    try {
      await db.insertRow(activeSchema.id, newRowData);
      setShowInsert(false);
      setNewRowData({});
      toast({ title: "Donnée ajoutée" });
    } catch (e: any) {
      toast({ title: "Erreur", description: e.message, variant: "destructive" });
    }
  };

  const handleDeleteSelected = async () => {
    for (const id of selectedRows) {
      await db.deleteRow(id);
    }
    setSelectedRows(new Set());
    toast({ title: `${selectedRows.size} ligne(s) supprimée(s)` });
  };

  const addColumn = (cols: Column[], setCols: (c: Column[]) => void) => {
    setCols([...cols, { name: "", type: "text", required: false }]);
  };

  const removeColumn = (cols: Column[], setCols: (c: Column[]) => void, idx: number) => {
    setCols(cols.filter((_, i) => i !== idx));
  };

  const updateColumn = (cols: Column[], setCols: (c: Column[]) => void, idx: number, field: keyof Column, value: any) => {
    const next = [...cols];
    (next[idx] as any)[field] = value;
    setCols(next);
  };

  const ColumnEditor = ({ columns, setColumns }: { columns: Column[]; setColumns: (c: Column[]) => void }) => (
    <div className="space-y-2">
      {columns.map((col, i) => (
        <div key={i} className="flex gap-2 items-center">
          <Input
            placeholder="Nom colonne"
            value={col.name}
            onChange={(e) => updateColumn(columns, setColumns, i, "name", e.target.value)}
            className="flex-1"
          />
          <Select
            value={col.type}
            onValueChange={(v) => updateColumn(columns, setColumns, i, "type", v)}
          >
            <SelectTrigger className="w-28">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {COLUMN_TYPES.map((t) => (
                <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Checkbox
            checked={col.required}
            onCheckedChange={(v) => updateColumn(columns, setColumns, i, "required", !!v)}
          />
          <span className="text-xs text-muted-foreground w-12">Requis</span>
          <Button size="icon" variant="ghost" onClick={() => removeColumn(columns, setColumns, i)}>
            <Trash2 className="h-3 w-3 text-destructive" />
          </Button>
        </div>
      ))}
      <Button size="sm" variant="outline" onClick={() => addColumn(columns, setColumns)}>
        <Plus className="h-3 w-3 mr-1" /> Colonne
      </Button>
    </div>
  );

  return (
    <DashboardLayout>
      <div className="px-4 py-6 md:px-8 md:py-8">
        <div className="mb-6 flex items-center justify-between">
          <div>
            {activeSchema ? (
              <div className="flex items-center gap-3">
                <Button size="icon" variant="ghost" onClick={() => { setActiveSchema(null); setTab("tables"); }}>
                  <ArrowLeft className="h-4 w-4" />
                </Button>
                <div>
                  <h1 className="text-2xl font-bold flex items-center gap-2">
                    <Table2 className="h-5 w-5 text-primary" />
                    {activeSchema.table_name}
                  </h1>
                  <p className="text-xs text-muted-foreground">{activeSchema.description || "Aucune description"}</p>
                </div>
              </div>
            ) : (
              <div>
                <h1 className="text-3xl font-bold tracking-tight">
                  <span className="text-gradient-primary">Base de données</span>
                </h1>
                <p className="text-sm text-muted-foreground mt-1">
                  Créez, modifiez et gérez vos tables et données
                </p>
              </div>
            )}
          </div>
          {!activeSchema && (
            <Dialog open={showCreate} onOpenChange={setShowCreate}>
              <DialogTrigger asChild>
                <Button><Plus className="h-4 w-4 mr-2" /> Nouvelle table</Button>
              </DialogTrigger>
              <DialogContent className="max-w-lg">
                <DialogHeader>
                  <DialogTitle>Créer une table</DialogTitle>
                </DialogHeader>
                <div className="space-y-4">
                  <Input placeholder="Nom de la table" value={newTableName} onChange={(e) => setNewTableName(e.target.value)} />
                  <Input placeholder="Description (optionnel)" value={newTableDesc} onChange={(e) => setNewTableDesc(e.target.value)} />
                  <div>
                    <p className="text-sm font-medium mb-2">Colonnes</p>
                    <ColumnEditor columns={newColumns} setColumns={setNewColumns} />
                  </div>
                  <Button onClick={handleCreateTable} className="w-full">
                    <Database className="h-4 w-4 mr-2" /> Créer la table
                  </Button>
                </div>
              </DialogContent>
            </Dialog>
          )}
        </div>

        {!activeSchema ? (
          /* Tables List */
          <div className="grid gap-4 grid-cols-1 md:grid-cols-2 lg:grid-cols-3">
            {db.loading ? (
              <div className="col-span-full flex justify-center py-12">
                <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
              </div>
            ) : db.schemas.length === 0 ? (
              <Card className="col-span-full">
                <CardContent className="flex flex-col items-center py-12 text-center">
                  <Database className="h-12 w-12 text-muted-foreground/50 mb-4" />
                  <p className="text-muted-foreground">Aucune table créée</p>
                  <p className="text-xs text-muted-foreground mt-1">Cliquez sur « Nouvelle table » pour commencer</p>
                </CardContent>
              </Card>
            ) : (
              db.schemas.map((s) => (
                <Card
                  key={s.id}
                  className="cursor-pointer hover:border-primary/50 transition-colors"
                  onClick={() => { setActiveSchema(s); setTab("data"); }}
                >
                  <CardHeader className="pb-2">
                    <CardTitle className="text-base flex items-center justify-between">
                      <span className="flex items-center gap-2">
                        <Table2 className="h-4 w-4 text-primary" />
                        {s.table_name}
                      </span>
                      <div className="flex gap-1">
                        <Button
                          size="icon"
                          variant="ghost"
                          onClick={(e) => {
                            e.stopPropagation();
                            setEditingSchema(s);
                            setEditColumns([...(s.columns as Column[])]);
                          }}
                        >
                          <Edit className="h-3 w-3" />
                        </Button>
                        <Button
                          size="icon"
                          variant="ghost"
                          onClick={(e) => {
                            e.stopPropagation();
                            db.deleteSchema(s.id);
                          }}
                        >
                          <Trash2 className="h-3 w-3 text-destructive" />
                        </Button>
                      </div>
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <p className="text-xs text-muted-foreground mb-2">{s.description || "—"}</p>
                    <div className="flex flex-wrap gap-1">
                      {(s.columns as Column[]).map((c) => (
                        <Badge key={c.name} variant="secondary" className="text-[10px]">
                          {c.name}: {c.type}
                        </Badge>
                      ))}
                    </div>
                    <p className="text-[10px] text-muted-foreground mt-2">
                      Créée le {new Date(s.created_at).toLocaleDateString("fr-FR")}
                    </p>
                  </CardContent>
                </Card>
              ))
            )}
          </div>
        ) : (
          /* Table Detail View */
          <Tabs value={tab} onValueChange={setTab}>
            <TabsList>
              <TabsTrigger value="data"><Rows3 className="h-3 w-3 mr-1" /> Données</TabsTrigger>
              <TabsTrigger value="schema"><Table2 className="h-3 w-3 mr-1" /> Schéma</TabsTrigger>
              <TabsTrigger value="migrations"><History className="h-3 w-3 mr-1" /> Migrations</TabsTrigger>
            </TabsList>

            <TabsContent value="data" className="mt-4">
              <div className="flex items-center justify-between mb-4">
                <p className="text-sm text-muted-foreground">{db.totalRows} ligne(s)</p>
                <div className="flex gap-2">
                  {selectedRows.size > 0 && (
                    <Button size="sm" variant="destructive" onClick={handleDeleteSelected}>
                      <Trash2 className="h-3 w-3 mr-1" /> Supprimer ({selectedRows.size})
                    </Button>
                  )}
                  <Dialog open={showInsert} onOpenChange={setShowInsert}>
                    <DialogTrigger asChild>
                      <Button size="sm"><Plus className="h-3 w-3 mr-1" /> Ajouter</Button>
                    </DialogTrigger>
                    <DialogContent>
                      <DialogHeader>
                        <DialogTitle>Ajouter une ligne</DialogTitle>
                      </DialogHeader>
                      <div className="space-y-3">
                        {(activeSchema.columns as Column[]).map((col) => (
                          <div key={col.name}>
                            <label className="text-xs font-medium">{col.name} <span className="text-muted-foreground">({col.type})</span></label>
                            <Input
                              value={newRowData[col.name] || ""}
                              onChange={(e) => setNewRowData((prev) => ({ ...prev, [col.name]: e.target.value }))}
                              placeholder={col.required ? "Requis" : "Optionnel"}
                            />
                          </div>
                        ))}
                        <Button onClick={handleInsertRow} className="w-full">
                          <Save className="h-4 w-4 mr-2" /> Insérer
                        </Button>
                      </div>
                    </DialogContent>
                  </Dialog>
                </div>
              </div>

              <div className="border rounded-lg overflow-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="w-10">
                        <Checkbox
                          checked={selectedRows.size === db.rows.length && db.rows.length > 0}
                          onCheckedChange={(v) => {
                            if (v) setSelectedRows(new Set(db.rows.map((r) => r.id)));
                            else setSelectedRows(new Set());
                          }}
                        />
                      </TableHead>
                      {(activeSchema.columns as Column[]).map((col) => (
                        <TableHead key={col.name}>{col.name}</TableHead>
                      ))}
                      <TableHead className="w-10" />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {db.rows.length === 0 ? (
                      <TableRow>
                        <TableCell colSpan={(activeSchema.columns as Column[]).length + 2} className="text-center py-8 text-muted-foreground">
                          Aucune donnée
                        </TableCell>
                      </TableRow>
                    ) : (
                      db.rows.map((row) => (
                        <TableRow key={row.id}>
                          <TableCell>
                            <Checkbox
                              checked={selectedRows.has(row.id)}
                              onCheckedChange={(v) => {
                                const next = new Set(selectedRows);
                                v ? next.add(row.id) : next.delete(row.id);
                                setSelectedRows(next);
                              }}
                            />
                          </TableCell>
                          {(activeSchema.columns as Column[]).map((col) => (
                            <TableCell key={col.name} className="text-sm">
                              {row.row_data?.[col.name] ?? "—"}
                            </TableCell>
                          ))}
                          <TableCell>
                            <Button size="icon" variant="ghost" onClick={() => db.deleteRow(row.id)}>
                              <Trash2 className="h-3 w-3 text-destructive" />
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </div>
            </TabsContent>

            <TabsContent value="schema" className="mt-4">
              <Card>
                <CardHeader>
                  <CardTitle className="text-base">Structure de la table</CardTitle>
                </CardHeader>
                <CardContent>
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Colonne</TableHead>
                        <TableHead>Type</TableHead>
                        <TableHead>Requis</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {(activeSchema.columns as Column[]).map((col) => (
                        <TableRow key={col.name}>
                          <TableCell className="font-mono text-sm">{col.name}</TableCell>
                          <TableCell><Badge variant="outline">{col.type}</Badge></TableCell>
                          <TableCell>{col.required ? "✓" : "—"}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                  <Button
                    className="mt-4"
                    variant="outline"
                    onClick={() => {
                      setEditingSchema(activeSchema);
                      setEditColumns([...(activeSchema.columns as Column[])]);
                    }}
                  >
                    <Edit className="h-4 w-4 mr-2" /> Modifier le schéma
                  </Button>
                </CardContent>
              </Card>
            </TabsContent>

            <TabsContent value="migrations" className="mt-4">
              <div className="space-y-3">
                {db.migrations.length === 0 ? (
                  <p className="text-sm text-muted-foreground text-center py-8">Aucune migration</p>
                ) : (
                  db.migrations.map((m) => (
                    <Card key={m.id}>
                      <CardContent className="py-3 flex items-center gap-3">
                        <History className="h-4 w-4 text-primary" />
                        <div className="flex-1">
                          <p className="text-sm font-medium">{m.migration_type}</p>
                          <p className="text-xs text-muted-foreground">
                            {new Date(m.applied_at).toLocaleString("fr-FR")}
                          </p>
                        </div>
                        <pre className="text-[10px] bg-muted p-2 rounded max-w-xs overflow-auto">
                          {JSON.stringify(m.migration_details, null, 2)}
                        </pre>
                      </CardContent>
                    </Card>
                  ))
                )}
              </div>
            </TabsContent>
          </Tabs>
        )}

        {/* Edit Schema Dialog */}
        <Dialog open={!!editingSchema} onOpenChange={(v) => !v && setEditingSchema(null)}>
          <DialogContent className="max-w-lg">
            <DialogHeader>
              <DialogTitle>Modifier le schéma — {editingSchema?.table_name}</DialogTitle>
            </DialogHeader>
            <div className="space-y-4">
              <ColumnEditor columns={editColumns} setColumns={setEditColumns} />
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <AlertTriangle className="h-3 w-3" /> Les données existantes ne seront pas modifiées
              </div>
              <Button onClick={handleUpdateColumns} className="w-full">
                <Save className="h-4 w-4 mr-2" /> Appliquer la migration
              </Button>
            </div>
          </DialogContent>
        </Dialog>
      </div>
    </DashboardLayout>
  );
}

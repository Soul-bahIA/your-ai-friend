import { useState, useEffect } from "react";
import DashboardLayout from "@/components/DashboardLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { BookOpen, Plus, Search, Trash2, Edit, Tag, Calendar } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { toast } from "sonner";

type Knowledge = {
  id: string;
  title: string;
  content: string;
  category: string;
  source: string | null;
  tags: string[];
  created_at: string;
  updated_at: string;
};

const CATEGORIES = ["general", "formation", "application", "code", "recherche", "note"];

const KnowledgeBase = () => {
  const { user } = useAuth();
  const [items, setItems] = useState<Knowledge[]>([]);
  const [search, setSearch] = useState("");
  const [filterCategory, setFilterCategory] = useState<string>("all");
  const [isOpen, setIsOpen] = useState(false);
  const [editing, setEditing] = useState<Knowledge | null>(null);
  const [form, setForm] = useState({ title: "", content: "", category: "general", source: "", tags: "" });

  const loadItems = async () => {
    if (!user) return;
    const { data } = await supabase
      .from("knowledge_base")
      .select("*")
      .eq("user_id", user.id)
      .order("updated_at", { ascending: false });
    if (data) setItems(data as Knowledge[]);
  };

  useEffect(() => { loadItems(); }, [user]);

  const handleSave = async () => {
    if (!user || !form.title.trim() || !form.content.trim()) {
      toast.error("Titre et contenu requis");
      return;
    }
    const tags = form.tags.split(",").map(t => t.trim()).filter(Boolean);
    const payload = {
      user_id: user.id,
      title: form.title,
      content: form.content,
      category: form.category,
      source: form.source || null,
      tags,
    };

    if (editing) {
      const { error } = await supabase.from("knowledge_base").update(payload).eq("id", editing.id);
      if (error) { toast.error("Erreur mise à jour"); return; }
      toast.success("Connaissance mise à jour");
    } else {
      const { error } = await supabase.from("knowledge_base").insert(payload);
      if (error) { toast.error("Erreur création"); return; }
      toast.success("Connaissance ajoutée");
    }
    setIsOpen(false);
    setEditing(null);
    setForm({ title: "", content: "", category: "general", source: "", tags: "" });
    loadItems();
  };

  const handleDelete = async (id: string) => {
    await supabase.from("knowledge_base").delete().eq("id", id);
    toast.success("Supprimé");
    loadItems();
  };

  const openEdit = (item: Knowledge) => {
    setEditing(item);
    setForm({
      title: item.title,
      content: item.content,
      category: item.category,
      source: item.source || "",
      tags: item.tags?.join(", ") || "",
    });
    setIsOpen(true);
  };

  const openNew = () => {
    setEditing(null);
    setForm({ title: "", content: "", category: "general", source: "", tags: "" });
    setIsOpen(true);
  };

  const filtered = items.filter(item => {
    const matchSearch = !search || item.title.toLowerCase().includes(search.toLowerCase()) || item.content.toLowerCase().includes(search.toLowerCase());
    const matchCategory = filterCategory === "all" || item.category === filterCategory;
    return matchSearch && matchCategory;
  });

  return (
    <DashboardLayout>
      <div className="px-4 py-6 md:px-8 md:py-8">
        <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 className="text-3xl font-bold tracking-tight">
              Base de <span className="text-gradient-primary">Connaissances</span>
            </h1>
            <p className="text-sm text-muted-foreground mt-1">
              {items.length} entrée{items.length !== 1 ? "s" : ""} stockées localement
            </p>
          </div>
          <Dialog open={isOpen} onOpenChange={setIsOpen}>
            <DialogTrigger asChild>
              <Button onClick={openNew} className="gap-2"><Plus className="h-4 w-4" /> Ajouter</Button>
            </DialogTrigger>
            <DialogContent className="max-w-lg">
              <DialogHeader>
                <DialogTitle>{editing ? "Modifier" : "Ajouter"} une connaissance</DialogTitle>
              </DialogHeader>
              <div className="space-y-4 pt-2">
                <Input placeholder="Titre" value={form.title} onChange={e => setForm(f => ({ ...f, title: e.target.value }))} />
                <Textarea placeholder="Contenu..." rows={6} value={form.content} onChange={e => setForm(f => ({ ...f, content: e.target.value }))} />
                <div className="flex gap-3">
                  <Select value={form.category} onValueChange={v => setForm(f => ({ ...f, category: v }))}>
                    <SelectTrigger className="w-40"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      {CATEGORIES.map(c => <SelectItem key={c} value={c}>{c}</SelectItem>)}
                    </SelectContent>
                  </Select>
                  <Input placeholder="Source (URL)" value={form.source} onChange={e => setForm(f => ({ ...f, source: e.target.value }))} className="flex-1" />
                </div>
                <Input placeholder="Tags (séparés par virgule)" value={form.tags} onChange={e => setForm(f => ({ ...f, tags: e.target.value }))} />
                <Button onClick={handleSave} className="w-full">{editing ? "Mettre à jour" : "Sauvegarder"}</Button>
              </div>
            </DialogContent>
          </Dialog>
        </div>

        {/* Filters */}
        <div className="flex flex-col gap-3 sm:flex-row mb-6">
          <div className="relative flex-1 sm:max-w-sm">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
            <Input placeholder="Rechercher..." value={search} onChange={e => setSearch(e.target.value)} className="pl-10" />
          </div>
          <Select value={filterCategory} onValueChange={setFilterCategory}>
            <SelectTrigger className="w-40"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Toutes</SelectItem>
              {CATEGORIES.map(c => <SelectItem key={c} value={c}>{c}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>

        {/* Items */}
        <ScrollArea className="h-[calc(100vh-280px)]">
          <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            {filtered.map(item => (
              <Card key={item.id} className="p-4 flex flex-col gap-3 hover:border-primary/30 transition-colors">
                <div className="flex items-start justify-between">
                  <div className="flex items-center gap-2">
                    <BookOpen className="h-4 w-4 text-primary" />
                    <h3 className="font-semibold text-sm text-foreground truncate">{item.title}</h3>
                  </div>
                  <div className="flex gap-1">
                    <button onClick={() => openEdit(item)} className="text-muted-foreground hover:text-primary transition-colors">
                      <Edit className="h-3.5 w-3.5" />
                    </button>
                    <button onClick={() => handleDelete(item.id)} className="text-muted-foreground hover:text-destructive transition-colors">
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                </div>
                <p className="text-xs text-muted-foreground line-clamp-3">{item.content}</p>
                <div className="flex items-center gap-2 flex-wrap mt-auto">
                  <Badge variant="secondary" className="text-[10px]">{item.category}</Badge>
                  {item.tags?.slice(0, 3).map(tag => (
                    <Badge key={tag} variant="outline" className="text-[10px] gap-1">
                      <Tag className="h-2.5 w-2.5" />{tag}
                    </Badge>
                  ))}
                </div>
                <div className="flex items-center gap-1 text-[10px] text-muted-foreground">
                  <Calendar className="h-3 w-3" />
                  {new Date(item.updated_at).toLocaleDateString("fr-FR")}
                </div>
              </Card>
            ))}
          </div>
          {filtered.length === 0 && (
            <div className="text-center py-16">
              <BookOpen className="h-12 w-12 text-muted-foreground/30 mx-auto mb-3" />
              <p className="text-sm text-muted-foreground">Aucune connaissance trouvée</p>
            </div>
          )}
        </ScrollArea>
      </div>
    </DashboardLayout>
  );
};

export default KnowledgeBase;

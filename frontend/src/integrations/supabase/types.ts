// Types du schéma public, alignés sur supabase/migrations (dernière revue : LOT 4 — colonnes V2
// additives d'agent_keys, agent_memory, agent_tasks.v2_task_id, knowledge_base ; le schéma
// `soulbah` n'est pas exposé à PostgREST et n'apparaît donc pas ici).
// agent_tasks.target_agent_key_id / claimed_by_key_id : contrat LOT 1 §7.
export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.1"
  }
  public: {
    Tables: {
      agent_events: {
        Row: {
          created_at: string
          data: Json
          id: string
          message: string | null
          task_id: string
          type: string
          user_id: string
        }
        Insert: {
          created_at?: string
          data?: Json
          id?: string
          message?: string | null
          task_id: string
          type: string
          user_id: string
        }
        Update: {
          created_at?: string
          data?: Json
          id?: string
          message?: string | null
          task_id?: string
          type?: string
          user_id?: string
        }
        Relationships: []
      }
      agent_keys: {
        Row: {
          capabilities: Json
          expires_at: string | null
          kind: string
          last_seen_at: string | null
          scopes: Json
          allowed_dirs: Json
          created_at: string
          id: string
          key_hash: string
          label: string | null
          last_used_at: string | null
          user_id: string
        }
        Insert: {
          capabilities?: Json
          expires_at?: string | null
          kind?: string
          last_seen_at?: string | null
          scopes?: Json
          allowed_dirs?: Json
          created_at?: string
          id?: string
          key_hash: string
          label?: string | null
          last_used_at?: string | null
          user_id: string
        }
        Update: {
          capabilities?: Json
          expires_at?: string | null
          kind?: string
          last_seen_at?: string | null
          scopes?: Json
          allowed_dirs?: Json
          created_at?: string
          id?: string
          key_hash?: string
          label?: string | null
          last_used_at?: string | null
          user_id?: string
        }
        Relationships: []
      }
      agent_memory: {
        Row: {
          confidence: number
          evidence_ids: Json
          expires_at: string | null
          is_simulation: boolean
          scope: string
          session_id: string | null
          source_task_id: string | null
          validated_at: string | null
          validated_by: string | null
          content: string
          created_at: string
          goal: string
          id: string
          level: string
          metadata: Json
          project_id: string | null
          status: string
          type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          confidence?: number
          evidence_ids?: Json
          expires_at?: string | null
          is_simulation?: boolean
          scope?: string
          session_id?: string | null
          source_task_id?: string | null
          validated_at?: string | null
          validated_by?: string | null
          content: string
          created_at?: string
          goal: string
          id?: string
          level?: string
          metadata?: Json
          project_id?: string | null
          status?: string
          type: string
          updated_at?: string
          user_id: string
        }
        Update: {
          confidence?: number
          evidence_ids?: Json
          expires_at?: string | null
          is_simulation?: boolean
          scope?: string
          session_id?: string | null
          source_task_id?: string | null
          validated_at?: string | null
          validated_by?: string | null
          content?: string
          created_at?: string
          goal?: string
          id?: string
          level?: string
          metadata?: Json
          project_id?: string | null
          status?: string
          type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      agent_tasks: {
        Row: {
          v2_task_id: string | null
          claimed_by_key_id: string | null
          completed_at: string | null
          control: string
          created_at: string
          error_message: string | null
          id: string
          payload: Json
          priority: number
          requeue_count: number
          result: Json | null
          started_at: string | null
          status: string
          target_agent_key_id: string | null
          task_type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          v2_task_id?: string | null
          claimed_by_key_id?: string | null
          completed_at?: string | null
          control?: string
          created_at?: string
          error_message?: string | null
          id?: string
          payload?: Json
          priority?: number
          requeue_count?: number
          result?: Json | null
          started_at?: string | null
          status?: string
          target_agent_key_id?: string | null
          task_type: string
          updated_at?: string
          user_id: string
        }
        Update: {
          v2_task_id?: string | null
          claimed_by_key_id?: string | null
          completed_at?: string | null
          control?: string
          created_at?: string
          error_message?: string | null
          id?: string
          payload?: Json
          priority?: number
          requeue_count?: number
          result?: Json | null
          started_at?: string | null
          status?: string
          target_agent_key_id?: string | null
          task_type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_tasks_claimed_by_key_id_fkey"
            columns: ["claimed_by_key_id"]
            isOneToOne: false
            referencedRelation: "agent_keys"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_tasks_target_agent_key_id_fkey"
            columns: ["target_agent_key_id"]
            isOneToOne: false
            referencedRelation: "agent_keys"
            referencedColumns: ["id"]
          },
        ]
      }
      analysis_requests: {
        Row: {
          created_at: string
          id: string
          input_text: string
          result: Json | null
          status: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          input_text: string
          result?: Json | null
          status?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          input_text?: string
          result?: Json | null
          status?: string
          user_id?: string | null
        }
        Relationships: []
      }
      applications: {
        Row: {
          app_type: string | null
          created_at: string
          description: string | null
          id: string
          source_code: Json | null
          status: string
          tech_stack: string | null
          title: string
          updated_at: string
          user_id: string
        }
        Insert: {
          app_type?: string | null
          created_at?: string
          description?: string | null
          id?: string
          source_code?: Json | null
          status?: string
          tech_stack?: string | null
          title: string
          updated_at?: string
          user_id: string
        }
        Update: {
          app_type?: string | null
          created_at?: string
          description?: string | null
          id?: string
          source_code?: Json | null
          status?: string
          tech_stack?: string | null
          title?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      chat_conversations: {
        Row: {
          created_at: string
          id: string
          title: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          title?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      chat_messages: {
        Row: {
          content: string
          conversation_id: string
          created_at: string
          id: string
          role: string
          user_id: string
        }
        Insert: {
          content: string
          conversation_id: string
          created_at?: string
          id?: string
          role: string
          user_id: string
        }
        Update: {
          content?: string
          conversation_id?: string
          created_at?: string
          id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "chat_messages_conversation_id_fkey"
            columns: ["conversation_id"]
            isOneToOne: false
            referencedRelation: "chat_conversations"
            referencedColumns: ["id"]
          },
        ]
      }
      formations: {
        Row: {
          content: Json | null
          created_at: string
          curriculum: Json | null
          description: string | null
          duration: string | null
          id: string
          lessons_count: number | null
          pdf_url: string | null
          status: string
          title: string
          updated_at: string
          user_id: string
          video_url: string | null
        }
        Insert: {
          content?: Json | null
          created_at?: string
          curriculum?: Json | null
          description?: string | null
          duration?: string | null
          id?: string
          lessons_count?: number | null
          pdf_url?: string | null
          status?: string
          title: string
          updated_at?: string
          user_id: string
          video_url?: string | null
        }
        Update: {
          content?: Json | null
          created_at?: string
          curriculum?: Json | null
          description?: string | null
          duration?: string | null
          id?: string
          lessons_count?: number | null
          pdf_url?: string | null
          status?: string
          title?: string
          updated_at?: string
          user_id?: string
          video_url?: string | null
        }
        Relationships: []
      }
      knowledge_base: {
        Row: {
          doc_status: string | null
          embedding_model: string | null
          ingest_status: string | null
          last_written_at: string | null
          mime: string | null
          source_uri: string | null
          category: string
          confidence: number
          content: string
          content_hash: string | null
          created_at: string
          description: string | null
          domain: string
          embedding: string | null
          id: string
          keywords: string[]
          last_verified_at: string | null
          links: Json
          source: string | null
          sources: Json
          summary: string | null
          tags: string[] | null
          title: string
          updated_at: string
          user_id: string
          version: number
        }
        Insert: {
          doc_status?: string | null
          embedding_model?: string | null
          ingest_status?: string | null
          last_written_at?: string | null
          mime?: string | null
          source_uri?: string | null
          category?: string
          confidence?: number
          content: string
          content_hash?: string | null
          created_at?: string
          description?: string | null
          domain?: string
          embedding?: string | null
          id?: string
          keywords?: string[]
          last_verified_at?: string | null
          links?: Json
          source?: string | null
          sources?: Json
          summary?: string | null
          tags?: string[] | null
          title: string
          updated_at?: string
          user_id: string
          version?: number
        }
        Update: {
          doc_status?: string | null
          embedding_model?: string | null
          ingest_status?: string | null
          last_written_at?: string | null
          mime?: string | null
          source_uri?: string | null
          category?: string
          confidence?: number
          content?: string
          content_hash?: string | null
          created_at?: string
          description?: string | null
          domain?: string
          embedding?: string | null
          id?: string
          keywords?: string[]
          last_verified_at?: string | null
          links?: Json
          source?: string | null
          sources?: Json
          summary?: string | null
          tags?: string[] | null
          title?: string
          updated_at?: string
          user_id?: string
          version?: number
        }
        Relationships: []
      }
      knowledge_domains: {
        Row: {
          created_at: string
          is_system: boolean
          label: string
          slug: string
        }
        Insert: {
          created_at?: string
          is_system?: boolean
          label: string
          slug: string
        }
        Update: {
          created_at?: string
          is_system?: boolean
          label?: string
          slug?: string
        }
        Relationships: []
      }
      knowledge_versions: {
        Row: {
          change_note: string | null
          created_at: string
          entry_id: string
          id: string
          snapshot: Json
          user_id: string
          version: number
        }
        Insert: {
          change_note?: string | null
          created_at?: string
          entry_id: string
          id?: string
          snapshot: Json
          user_id: string
          version: number
        }
        Update: {
          change_note?: string | null
          created_at?: string
          entry_id?: string
          id?: string
          snapshot?: Json
          user_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "knowledge_versions_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "knowledge_base"
            referencedColumns: ["id"]
          },
        ]
      }
      modules_status: {
        Row: {
          id: string
          last_active: string | null
          module_name: string
          stats: string | null
          status: string
          user_id: string
        }
        Insert: {
          id?: string
          last_active?: string | null
          module_name: string
          stats?: string | null
          status?: string
          user_id: string
        }
        Update: {
          id?: string
          last_active?: string | null
          module_name?: string
          stats?: string | null
          status?: string
          user_id?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          avatar_url: string | null
          bio: string | null
          created_at: string
          display_name: string | null
          id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          avatar_url?: string | null
          bio?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          avatar_url?: string | null
          bio?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      system_logs: {
        Row: {
          created_at: string
          details: Json | null
          event: string
          id: string
          level: string
          module: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          details?: Json | null
          event: string
          id?: string
          level?: string
          module: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          details?: Json | null
          event?: string
          id?: string
          level?: string
          module?: string
          user_id?: string | null
        }
        Relationships: []
      }
      user_migrations: {
        Row: {
          applied_at: string
          id: string
          migration_details: Json
          migration_type: string
          schema_id: string
          user_id: string
        }
        Insert: {
          applied_at?: string
          id?: string
          migration_details?: Json
          migration_type: string
          schema_id: string
          user_id: string
        }
        Update: {
          applied_at?: string
          id?: string
          migration_details?: Json
          migration_type?: string
          schema_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_migrations_schema_id_fkey"
            columns: ["schema_id"]
            isOneToOne: false
            referencedRelation: "user_schemas"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
      user_schemas: {
        Row: {
          columns: Json
          created_at: string
          description: string | null
          id: string
          table_name: string
          updated_at: string
          user_id: string
        }
        Insert: {
          columns?: Json
          created_at?: string
          description?: string | null
          id?: string
          table_name: string
          updated_at?: string
          user_id: string
        }
        Update: {
          columns?: Json
          created_at?: string
          description?: string | null
          id?: string
          table_name?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_table_data: {
        Row: {
          created_at: string
          id: string
          row_data: Json
          schema_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          row_data?: Json
          schema_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          row_data?: Json
          schema_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_table_data_schema_id_fkey"
            columns: ["schema_id"]
            isOneToOne: false
            referencedRelation: "user_schemas"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
    }
    Enums: {
      app_role: "admin" | "moderator" | "user"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "moderator", "user"],
    },
  },
} as const

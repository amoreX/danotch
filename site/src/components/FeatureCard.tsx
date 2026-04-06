import { motion } from 'framer-motion';
import type { LucideIcon } from 'lucide-react';

interface FeatureCardProps {
  icon: LucideIcon;
  title: string;
  description: string;
  index?: number;
  variant?: 'default' | 'glass' | 'border' | 'gradient' | 'minimal';
}

const variants = {
  default: 'bg-white/5 border border-white/10 hover:border-white/20',
  glass: 'bg-white/5 backdrop-blur-xl border border-white/10 hover:bg-white/10',
  border: 'border border-white/10 hover:border-[#D97757]/50',
  gradient: 'bg-gradient-to-br from-white/5 to-transparent border border-white/5 hover:from-white/10',
  minimal: 'hover:bg-white/5',
};

export function FeatureCard({ icon: Icon, title, description, index = 0, variant = 'default' }: FeatureCardProps) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true }}
      transition={{ delay: index * 0.1, duration: 0.5 }}
      className={`p-6 rounded-2xl transition-all duration-300 cursor-pointer ${variants[variant]}`}
    >
      <div className="w-10 h-10 rounded-xl bg-white/5 flex items-center justify-center mb-4">
        <Icon className="w-5 h-5 text-white/70" />
      </div>
      <h3 className="text-white font-medium mb-2">{title}</h3>
      <p className="text-sm text-white/50 leading-relaxed">{description}</p>
    </motion.div>
  );
}

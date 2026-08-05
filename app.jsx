import React, { useState, useEffect, useRef, Fragment } from 'react';
import ReactDOM from 'react-dom/client';
import * as Lucide from 'lucide-react';
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
  BarChart, Bar, Cell, PieChart, Pie, Legend
} from 'recharts';

/* Lightweight motion shim: the original used `motion/react` only for decorative
   entrance/tap animations. We render the plain element and drop motion-only props
   so content is always visible (and we shed a fragile CDN dependency). */
const __MOTION_PROPS = new Set(['initial','animate','exit','transition','variants','whileHover','whileTap','whileFocus','whileDrag','whileInView','viewport','layout','layoutId','layoutScroll','drag','dragConstraints','dragElastic','dragMomentum','onAnimationStart','onAnimationComplete','custom','style']);
const motion = new Proxy({}, {
  get: (_t, tag) => React.forwardRef((props, ref) => {
    const clean = {};
    for (const k in props) { if (!__MOTION_PROPS.has(k)) clean[k] = props[k]; }
    if (props.style) clean.style = props.style;
    return React.createElement(typeof tag === 'string' ? tag : 'div', { ...clean, ref });
  })
});
const AnimatePresence = ({ children }) => React.createElement(React.Fragment, null, children);

/* ICONS: the constants module curated a subset of lucide-react; the full
   namespace is a superset, so it satisfies every component (incl. the ones
   that did `import * as ICONS from 'lucide-react'`). */
const ICONS = Lucide;
const NJE_LOGO = "nje-logo.svg";

const AppView = {
  AGENT_PORTAL: 'agent_portal',
  ADMISSIONS_CORE: 'admissions_core',
  ENGAGEMENT_CRM: 'engagement_crm',
  FINANCE: 'finance',
  IMMIGRATION: 'immigration',
  EVALUATION: 'evaluation',
  SYSTEM_ADMIN: 'system_admin',
  INTERVIEWS: 'interviews',
  STUDENT_PORTAL: 'student_portal',
  MARKETING_LEADS: 'marketing_leads',
  REPORTS: 'reports',
  INTELLIGENCE: 'intelligence',
  FEED: 'feed',
  PROGRAMS: 'programs',
  TRAININGS: 'trainings',
  ASSISTANT: 'assistant',
  REGISTRATIONS: 'registrations',
};

const MENU_ITEMS = [
  { id: AppView.FEED, label: 'Hírfolyam', icon: <Lucide.Newspaper size={20} /> },
  { id: AppView.PROGRAMS, label: 'Programok', icon: <Lucide.BookOpen size={20} /> },
  { id: AppView.TRAININGS, label: 'Képzések', icon: <Lucide.GraduationCap size={20} /> },
  { id: AppView.ASSISTANT, label: 'AI Asszisztens', icon: <Lucide.Sparkles size={20} /> },
  { id: AppView.AGENT_PORTAL, label: 'Ügynök és partner portál', icon: <Lucide.Briefcase size={20} /> },
  { id: AppView.ADMISSIONS_CORE, label: 'Jelentkezés és Felvételi', icon: <Lucide.FileText size={20} /> },
  { id: AppView.ENGAGEMENT_CRM, label: 'Kommunikáció és CRM', icon: <Lucide.MessageSquare size={20} /> },
  { id: AppView.FINANCE, label: 'Pénzügyek', icon: <Lucide.Wallet size={20} /> },
  { id: AppView.IMMIGRATION, label: 'Vízum és Compliance', icon: <Lucide.ShieldCheck size={20} /> },
  { id: AppView.EVALUATION, label: 'Felvételi Bírálat', icon: <Lucide.PieChart size={20} /> },
  { id: AppView.INTERVIEWS, label: 'Interjú Foglalás', icon: <Lucide.Calendar size={20} /> },
  { id: AppView.MARKETING_LEADS, label: 'Marketing és Lead kezelés', icon: <Lucide.Target size={20} /> },
  { id: AppView.STUDENT_PORTAL, label: 'Hallgatói Portál', icon: <Lucide.Users size={20} /> },
  { id: AppView.REPORTS, label: 'Riportok', icon: <Lucide.BarChart2 size={20} /> },
  { id: AppView.INTELLIGENCE, label: 'Intelligence', icon: <Lucide.Zap size={20} /> },
  { id: AppView.SYSTEM_ADMIN, label: 'Rendszerkezelés', icon: <Lucide.Settings size={20} /> },
  // Superadmin-only; the sidebar filter hides it from every other role.
  { id: AppView.REGISTRATIONS, label: 'Regisztrációk', icon: <Lucide.UserCheck size={20} /> },
];

/* ============ In-memory database (mirrors server.ts) ============ */
const db = {
  users: [
    { id: 'U1', name: 'Dr. Kovács István', email: 'admin@uni.hu', role: 'ADMIN', avatar: 'https://i.pravatar.cc/150?u=admin' },
    { id: 'U2', name: 'Szabó Péter', email: 'admissions@uni.hu', role: 'ADMISSIONS', avatar: 'https://i.pravatar.cc/150?u=admissions' },
    { id: 'U3', name: 'Nagy Ilona', email: 'finance@uni.hu', role: 'FINANCE', avatar: 'https://i.pravatar.cc/150?u=finance' },
    { id: 'U4', name: 'Al-Farabi Ammar', email: 'ammar@test.com', role: 'STUDENT', avatar: 'https://i.pravatar.cc/150?u=ammar' },
    { id: 'U5', name: 'Szalay Tamás', email: 'tamas@test.com', role: 'STUDENT', avatar: 'https://i.pravatar.cc/150?u=tamas' },
    { id: 'U6', name: 'Agent Smith', email: 'agent@globalstudy.com', role: 'AGENT', agencyId: 'AG1', avatar: 'https://i.pravatar.cc/150?u=agent' },
  ],
  students: [
    {
      id: 'S0', name: 'Szalay Tamás', email: 'tamas@test.com', phone: '+36301234567',
      program: 'MSc Software Engineering', status: 'Accepted', appliedAt: '2024.03.01', tuitionFee: 4800,
      country: 'Magyarország', birthDate: '1995.08.15', passportNumber: 'BH123456', gender: 'Male',
      address: { street: 'Kossuth Lajos utca 10', city: 'Budapest', zip: '1052', country: 'Magyarország' },
      educationHistory: [{ institution: 'BME', degree: 'BSc Computer Science', fieldOfStudy: 'Software Engineering', startDate: '2014', endDate: '2018', grade: '4.5' }],
      languageSkills: [{ language: 'Hungarian', level: 'Native' }, { language: 'English', level: 'C1', certificate: 'Cambridge Advanced' }],
      personalStatement: 'I want to deepen my knowledge in software architecture and cloud systems...',
      visaChecklist: [
        { id: '1', label: 'Érvényes útlevél másolata', required: true, status: 'Verified' },
        { id: '2', label: 'Anyagi fedezet igazolása', required: true, status: 'Uploaded' },
        { id: '3', label: 'Befogadó nyilatkozat', required: true, status: 'Verified' },
      ],
      recommendationLetters: [
        { id: 'RL1', studentId: 'S0', referee: { id: 'R1', name: 'Dr. Kiss László', email: 'laszlo.kiss@bme.hu', position: 'Egyetemi Docens', institution: 'BME', relationship: 'Szakdolgozati konzulens' }, status: 'Verified', requestedAt: '2024.03.05', receivedAt: '2024.03.10', letterUrl: '#' },
        { id: 'RL2', studentId: 'S0', referee: { id: 'R2', name: 'Kovács János', email: 'janos.kovacs@techcorp.com', position: 'Senior Software Architect', institution: 'TechCorp Solutions', relationship: 'Közvetlen felettes' }, status: 'Received', requestedAt: '2024.03.06', receivedAt: '2024.03.12', letterUrl: '#' },
      ],
      visaApplication: { id: 'V-S0', studentId: 'S0', type: 'D-type', status: 'Approved', submissionDate: '2024.03.15', decisionDate: '2024.03.20', expiryDate: '2025.03.20', visaNumber: 'HUN123456789', consulate: 'Budapest', riskFactors: [] },
    },
    { id: 'S1', name: 'Al-Farabi Ammar', email: 'ammar@test.com', phone: '+2348012345678', program: 'MSc Computer Science', status: 'Paid', appliedAt: '2024.03.01', tuitionFee: 5000, agentId: 'A1', country: 'Nigéria',
      visaChecklist: [
        { id: '1', label: 'Érvényes útlevél másolata', required: true, status: 'Verified' },
        { id: '2', label: 'Anyagi fedezet igazolása', required: true, status: 'Uploaded' },
        { id: '3', label: 'Befogadó nyilatkozat', required: true, status: 'Verified' },
      ],
      recommendationLetters: [
        { id: 'RL3', studentId: 'S1', referee: { id: 'R3', name: 'Prof. John Doe', email: 'john.doe@university.ng', position: 'Professor', institution: 'University of Lagos', relationship: 'Academic Advisor' }, status: 'Verified', requestedAt: '2024.02.15', receivedAt: '2024.02.20', letterUrl: '#' },
      ],
      visaApplication: { id: 'V-S1', studentId: 'S1', type: 'D-type', status: 'In Progress', submissionDate: '2024.03.10', consulate: 'Abuja', riskFactors: [{ label: 'Financial Gap', impact: 'Medium', description: 'Bank statement shows irregular deposits.' }] },
      evaluation: {
        criteria: [
          { id: '1', label: 'Szakmai Motiváció', maxScore: 5, currentScore: 4 },
          { id: '2', label: 'Tanulmányi Átlag (GPA)', maxScore: 10, currentScore: 8 },
          { id: '3', label: 'Nyelvi Készségek', maxScore: 5, currentScore: 5 },
          { id: '4', label: 'Szakmai Tapasztalat', maxScore: 5, currentScore: 4 },
          { id: '5', label: 'Ajánlólevelek Minősége', maxScore: 5, currentScore: 4 },
        ],
        comments: [{ id: 'C1', author: 'Dr. Szabó Péter', text: 'Kiváló technikai háttér.', timestamp: '10:20' }],
        videos: [{ id: 'V1', question: 'Miért választotta ezt a szakot?', videoUrl: '#', duration: '01:45' }],
      } },
    { id: 'S2', name: 'Chen Wei', email: 'chen@test.com', phone: '+8613812345678', program: 'BSc Business Admin', status: 'Submitted', appliedAt: '2024.03.18', tuitionFee: 4500, agentId: 'A1', country: 'Kína',
      visaChecklist: [
        { id: '1', label: 'Érvényes útlevél másolata', required: true, status: 'Pending' },
        { id: '2', label: 'Anyagi fedezet igazolása', required: true, status: 'Pending' },
      ],
      evaluation: {
        criteria: [
          { id: '1', label: 'Szakmai Motiváció', maxScore: 5, currentScore: 3 },
          { id: '2', label: 'Tanulmányi Átlag (GPA)', maxScore: 10, currentScore: 9 },
          { id: '3', label: 'Nyelvi Készségek', maxScore: 5, currentScore: 4 },
          { id: '4', label: 'Szakmai Tapasztalat', maxScore: 5, currentScore: 2 },
          { id: '5', label: 'Ajánlólevelek Minősége', maxScore: 5, currentScore: 5 },
        ],
        comments: [{ id: 'C1', author: 'Dr. Kovács István', text: 'Nagyon erős elméleti tudás.', timestamp: '09:15' }],
        videos: [{ id: 'V1', question: 'Miért választotta ezt a szakot?', videoUrl: '#', duration: '02:10' }],
      } },
    { id: 'S3', name: 'Elena Rodriguez', email: 'elena@test.com', program: 'MA Visual Arts', status: 'Missing Info', appliedAt: '2024.03.10', tuitionFee: 6000, agentId: 'A2', country: 'Brazília', visaChecklist: [{ id: '1', label: 'Érvényes útlevél másolata', required: true, status: 'Uploaded' }] },
    { id: 'S4', name: 'Lars Svensson', email: 'lars@test.com', program: 'MSc Computer Science', status: 'Accepted', appliedAt: '2024.02.20', tuitionFee: 5000, agentId: 'A1', country: 'Svédország', visaChecklist: [] },
    { id: 'S5', name: 'Yuki Tanaka', email: 'yuki@test.com', program: 'BSc Engineering', status: 'Draft', appliedAt: '2024.03.21', tuitionFee: 5500, agentId: 'A3', country: 'Japán', visaChecklist: [] },
    { id: 'S6', name: 'Ahmed Hassan', email: 'ahmed@test.com', program: 'MSc Data Science', status: 'Paid', appliedAt: '2024.01.15', tuitionFee: 5200, agentId: 'A1', country: 'Egyiptom',
      visaChecklist: [
        { id: '1', label: 'Érvényes útlevél másolata', required: true, status: 'Verified' },
        { id: '2', label: 'Anyagi fedezet igazolása', required: true, status: 'Verified' },
      ],
      visaApplication: { id: 'V-S6', studentId: 'S6', type: 'Residence Permit', status: 'Submitted', submissionDate: '2024.03.01', consulate: 'Cairo', riskFactors: [] } },
    { id: 'S7', name: 'Sofia Bianchi', email: 'sofia@test.com', program: 'MA Architecture', status: 'Submitted', appliedAt: '2024.03.19', tuitionFee: 5800, agentId: 'A2' },
    { id: 'S8', name: 'Igor Petrov', email: 'igor@test.com', program: 'BSc Physics', status: 'Accepted', appliedAt: '2024.02.28', tuitionFee: 4800, agentId: 'A3' },
    { id: 'S9', name: 'Maria Garcia', email: 'maria@test.com', program: 'LLM International Law', status: 'Missing Info', appliedAt: '2024.03.05', tuitionFee: 6500, agentId: 'A2' },
    { id: 'S10', name: 'John Smith', email: 'john@test.com', program: 'BSc Business Admin', status: 'Paid', appliedAt: '2023.12.10', tuitionFee: 4500, agentId: 'A1' },
  ],
  payments: [
    { id: 'P1', studentName: 'Al-Farabi Ammar', type: 'Tuition', amount: 5000, currency: 'EUR', status: 'Paid', date: '2024.03.20', method: 'Bank Transfer' },
    { id: 'P2', studentName: 'Chen Wei', type: 'Application Fee', amount: 50, currency: 'EUR', status: 'Pending', date: '2024.03.21', method: 'Bank Transfer', proofUrl: 'https://example.com/proofs/chenwei_transfer.pdf' },
    { id: 'P3', studentName: 'Ahmed Hassan', type: 'Tuition', amount: 5200, currency: 'EUR', status: 'Paid', date: '2024.02.01', method: 'Stripe' },
    { id: 'P4', studentName: 'John Smith', type: 'Tuition', amount: 4500, currency: 'EUR', status: 'Paid', date: '2024.01.10', method: 'PayPal' },
    { id: 'P5', studentName: 'Sofia Bianchi', type: 'Application Fee', amount: 50, currency: 'EUR', status: 'Failed', date: '2024.03.20', method: 'Stripe' },
  ],
  invoices: [
    { id: 'INV-1001', studentName: 'Elena Rodriguez', amount: 3200, currency: 'USD', dueDate: '2024.03.10', status: 'Overdue' },
    { id: 'INV-1002', studentName: 'Maria Garcia', amount: 6500, currency: 'EUR', dueDate: '2024.04.15', status: 'Sent' },
    { id: 'INV-1003', studentName: 'Chen Wei', amount: 4500, currency: 'EUR', dueDate: '2024.05.01', status: 'Draft' },
  ],
  campaigns: [
    { id: 'C1', title: 'Tavaszi Nyílt Nap 2024', segment: 'Minden érdeklődő', sentCount: 1250, openRate: 68, status: 'Sent' },
    { id: 'C2', title: 'Early Bird Kedvezmény', segment: 'Draft státuszúak', sentCount: 85, openRate: 42, status: 'Draft' },
  ],
  auditLogs: [
    { id: 'LOG-1', timestamp: '2024.03.21 14:32', user: 'admin@uni.hu', action: 'CRITICAL_SECURITY_UPDATE', target: 'RBAC Policy', changes: 'Elevated Finance access' },
    { id: 'LOG-2', timestamp: '2024.03.21 15:10', user: 'admissions@uni.hu', action: 'STUDENT_STATUS_CHANGE', target: 'Lars Svensson', changes: 'Submitted -> Accepted' },
    { id: 'LOG-3', timestamp: '2024.03.21 15:45', user: 'finance@uni.hu', action: 'PAYMENT_VERIFIED', target: 'Al-Farabi Ammar', changes: 'Pending -> Paid' },
    { id: 'LOG-4', timestamp: '2024.03.21 16:20', user: 'admin@uni.hu', action: 'WEBHOOK_CONFIG_UPDATE', target: 'Neptun Sync', changes: 'URL changed to v2' },
  ],
  webhooks: [
    { id: 'W1', url: 'https://api.neptun.hu/sync', event: 'STUDENT_ENROLLED', status: 'Active' },
    { id: 'W2', url: 'https://hooks.slack.com/services/T000/B000', event: 'NEW_APPLICATION', status: 'Active' },
  ],
  interviewSlots: [
    { id: 'S1', startTime: '2024-03-25T09:00:00Z', endTime: '2024-03-25T09:30:00Z', status: 'Available', interviewerId: 'U1', interviewerName: 'Dr. Kovács István' },
    { id: 'S2', startTime: '2024-03-25T10:00:00Z', endTime: '2024-03-25T10:30:00Z', status: 'Available', interviewerId: 'U1', interviewerName: 'Dr. Kovács István' },
    { id: 'S3', startTime: '2024-03-25T11:00:00Z', endTime: '2024-03-25T11:30:00Z', status: 'Available', interviewerId: 'U1', interviewerName: 'Dr. Kovács István' },
    { id: 'S4', startTime: '2024-03-26T14:00:00Z', endTime: '2024-03-26T14:30:00Z', status: 'Available', interviewerId: 'U2', interviewerName: 'Szabó Péter' },
    { id: 'S5', startTime: '2024-03-26T15:00:00Z', endTime: '2024-03-26T15:30:00Z', status: 'Available', interviewerId: 'U2', interviewerName: 'Szabó Péter' },
  ],
  agencies: [
    { id: 'AG1', name: 'Global Study Ltd.', commissionRate: 15, contactPerson: 'John Doe', email: 'john@globalstudy.com', status: 'Active' },
    { id: 'AG2', name: 'Elite Education', commissionRate: 10, contactPerson: 'Jane Smith', email: 'jane@eliteedu.com', status: 'Active' },
    { id: 'AG3', name: 'Direct Applicant', commissionRate: 0, contactPerson: '-', email: '-', status: 'Active' },
  ],
  leads: [
    { id: 'L1', name: 'James Wilson', email: 'james@example.com', phone: '+123456789', country: 'USA', source: 'Google Ads', utmSource: 'google', utmMedium: 'cpc', utmCampaign: 'spring_2024', status: 'New', createdAt: '2024.03.20' },
    { id: 'L2', name: 'Anna Müller', email: 'anna@example.de', phone: '+491234567', country: 'Németország', source: 'Facebook', utmSource: 'facebook', utmMedium: 'social', utmCampaign: 'international_students', status: 'Qualified', createdAt: '2024.03.18' },
    { id: 'L3', name: 'Li Wei', email: 'li@example.cn', phone: '+861234567', country: 'Kína', source: 'Direct', status: 'Contacted', createdAt: '2024.03.15' },
    { id: 'L4', name: 'Raj Patel', email: 'raj@example.in', phone: '+911234567', country: 'India', source: 'Google Ads', utmSource: 'google', utmMedium: 'cpc', utmCampaign: 'spring_2024', status: 'Converted', createdAt: '2024.03.10' },
  ],
  marketingCampaigns: [
    { id: 'MC1', name: 'Spring Enrollment 2024', platform: 'Google Ads', status: 'Active', budget: 5000, spent: 1200, leadsGenerated: 45, conversions: 12, startDate: '2024.03.01' },
    { id: 'MC2', name: 'International Outreach', platform: 'Facebook', status: 'Active', budget: 3000, spent: 800, leadsGenerated: 32, conversions: 8, startDate: '2024.03.05' },
    { id: 'MC3', name: 'Winter Webinar', platform: 'LinkedIn', status: 'Completed', budget: 2000, spent: 2000, leadsGenerated: 15, conversions: 3, startDate: '2024.01.15', endDate: '2024.02.15' },
  ],
  scholarships: [
    { id: 'SCH-1', name: 'Excellence Scholarship', type: 'Percentage', value: 25, criteria: 'GPA > 4.5', status: 'Active' },
    { id: 'SCH-2', name: 'Early Bird Discount', type: 'Fixed', value: 500, criteria: 'Apply before April 1st', status: 'Active' },
    { id: 'SCH-3', name: 'Regional Grant (Central Asia)', type: 'Fixed', value: 1000, criteria: 'Citizens of Kazakhstan, Uzbekistan', status: 'Inactive' },
  ],
  integrations: [
    { id: 'INT-1', provider: 'Stripe', status: 'Connected', mode: 'Test', lastSync: '2024.03.21 10:00' },
    { id: 'INT-2', provider: 'PayPal', status: 'Disconnected', mode: 'Test' },
    { id: 'INT-3', provider: 'Billingo', status: 'Connected', mode: 'Live', lastSync: '2024.03.21 09:30' },
    { id: 'INT-4', provider: 'Wise', status: 'Error', mode: 'Test' },
  ],
};

const mockDatabase = {
  videoInterviewQuestions: [
    { id: 'Q1', text: 'Kérjük, mutassa be magát röviden!', durationLimit: 60 },
    { id: 'Q2', text: 'Miért választotta a Neumann János Egyetemet?', durationLimit: 90 },
    { id: 'Q3', text: 'Milyen szakmai céljai vannak a diploma megszerzése után?', durationLimit: 120 },
    { id: 'Q4', text: 'Hogyan tervezi finanszírozni a tanulmányait?', durationLimit: 60 },
  ],
};

/* ============ Supabase-backed API (Step 4) ============
   The in-memory db has been replaced by live Supabase queries. Table column
   names match these object shapes exactly, so reads are a passthrough and the
   rest of the app is unchanged. Auth (real email+password) arrives in Step 5;
   for now access uses the public anon key with temporary demo RLS policies. */
const sb = window.sb;
if (!sb) console.error('Supabase client (window.sb) is not initialised.');

const uid = (p) => p + '-' + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);
const todayStr = () => new Date().toISOString().split('T')[0].replace(/-/g, '.');
const nowTs = () => { const d = new Date(), p = (n) => String(n).padStart(2, '0'); return d.getFullYear() + '.' + p(d.getMonth() + 1) + '.' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()); };

async function sbList(table, orderCol, ascending = true) {
  let qb = sb.from(table).select('*');
  if (orderCol) qb = qb.order(orderCol, { ascending });
  const { data, error } = await qb;
  if (error) throw error;
  return data || [];
}
async function sbUpdate(table, id, patch) {
  const { data, error } = await sb.from(table).update(patch).eq('id', id).select().single();
  if (error) throw error;
  return data;
}
async function sbInsert(table, row) {
  const { data, error } = await sb.from(table).insert(row).select().single();
  if (error) throw error;
  return data;
}
async function studentNameById(studentId) {
  if (!studentId) return '';
  const { data } = await sb.from('students').select('name').eq('id', studentId).maybeSingle();
  return (data && data.name) || '';
}

const api = {
  getUsers: () => sbList('users', 'id'),
  getStudents: () => sbList('students', 'id'),
  getPayments: () => sbList('payments', 'id'),
  getInvoices: () => sbList('invoices', 'id'),
  getScholarships: () => sbList('scholarships', 'id'),
  getIntegrations: () => sbList('integrations', 'id'),
  getCampaigns: () => sbList('campaigns', 'id'),
  getAuditLogs: () => sbList('auditLogs', 'timestamp', false),
  getWebhooks: () => sbList('webhooks', 'id'),
  getLeads: () => sbList('leads', 'id'),
  getMarketingCampaigns: () => sbList('marketingCampaigns', 'id'),
  getAgencies: () => sbList('agencies', 'id'),
  getInterviewSlots: () => sbList('interviewSlots', 'startTime'),

  updateStudent: (id, data) => sbUpdate('students', id, data),
  addStudent: (student) => sbInsert('students', { ...student, id: uid('S'), appliedAt: todayStr() }),
  sendConditionalAdmission: (id) => sbUpdate('students', id, { status: 'Accepted', paymentLink: '/payment/' + id }),
  addAgency: (agency) => sbInsert('agencies', { ...agency, id: uid('AG') }),
  updateAgency: (id, data) => sbUpdate('agencies', id, data),
  bookInterviewSlot: (slotId, studentId, studentName) => sbUpdate('interviewSlots', slotId, { status: 'Booked', studentId, studentName, teamsMeetingUrl: 'https://teams.microsoft.com/l/meetup-join/mock-meeting-id' }),
  processPayment: async ({ studentId, amount, method, type }) => {
    const studentName = await studentNameById(studentId);
    const np = await sbInsert('payments', { id: uid('P'), studentName, type: type || 'Tuition', amount, currency: 'EUR', status: 'Paid', date: todayStr(), method: method || 'Stripe' });
    if (studentId) await sb.from('students').update({ status: 'Paid' }).eq('id', studentId);
    return np;
  },
  submitBankTransfer: async ({ studentId, amount, type, proofName }) => {
    const studentName = await studentNameById(studentId);
    return sbInsert('payments', { id: uid('P'), studentName, type: type || 'Tuition', amount, currency: 'EUR', status: 'Pending', date: todayStr(), method: 'Bank Transfer', proofUrl: 'https://example.com/proofs/' + (proofName || 'transfer_receipt.pdf') });
  },
  verifyPayment: async (id) => {
    const p = await sbUpdate('payments', id, { status: 'Paid' });
    if (p && p.studentName) await sb.from('students').update({ status: 'Paid' }).eq('name', p.studentName);
    return p;
  },
  updateVisaChecklist: (id, checklist) => sbUpdate('students', id, { visaChecklist: checklist }),
  addPayment: async (payment) => {
    const np = await sbInsert('payments', { ...payment, id: uid('P'), date: todayStr() });
    if (np.type === 'Tuition' && np.status === 'Paid' && np.studentName) await sb.from('students').update({ status: 'Paid' }).eq('name', np.studentName);
    return np;
  },
  updateInvoice: (id, data) => sbUpdate('invoices', id, data),
  sendWhatsAppMessage: async (data) => {
    await sbInsert('auditLogs', { id: uid('LOG'), timestamp: nowTs(), user: 'System (WhatsApp)', action: 'WHATSAPP_MESSAGE_SENT', target: data.to, changes: data.text || ('Template: ' + data.template) });
    return { success: true, message_id: 'mock_' + Math.random().toString(36).substr(2, 9) };
  },
};

/* ============ Applicant documents (Supabase Storage) ============
   Uploaded documents live in the private `documents` bucket (migration 08),
   not inside admission_processes.data — a scanned passport as base64 inside
   a JSONB column that is rewritten on every autosave does not scale, and the
   old code silently dropped anything over 4 MB while reporting success.

   A stored entry is { fileName, type, size, path }. Entries created before
   this change still carry { dataUrl }; every reader goes through DOC_src(),
   so both keep working. */

const DOC_MAX_BYTES = 20 * 1024 * 1024;          // hard limit shown to the user
const DOC_INLINE_FALLBACK_BYTES = 4 * 1024 * 1024; // only if Storage is unavailable
const DOC_BUCKET = 'documents';

function DOC_fmtSize(bytes) {
  if (!bytes && bytes !== 0) return '';
  return bytes >= 1024 * 1024
    ? (bytes / (1024 * 1024)).toFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1) + ' MB'
    : Math.max(1, Math.round(bytes / 1024)) + ' KB';
}

// Keep object keys ASCII-safe: Storage rejects some characters in keys.
function DOC_safeName(name) {
  return String(name || 'file')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9._-]/g, '_')
    .slice(-80);
}

async function DOC_upload(file, ownerId, processId, docId) {
  if (!window.sb || !ownerId) throw new Error('storage-unavailable');
  const path = [ownerId, processId || 'draft', docId + '-' + Date.now().toString(36) + '-' + DOC_safeName(file.name)].join('/');
  const { error } = await sb.storage.from(DOC_BUCKET).upload(path, file, {
    upsert: true,
    contentType: file.type || 'application/octet-stream',
  });
  if (error) throw error;
  return path;
}

// Signed URLs expire, so cache per path for a little under the TTL.
const DOC_URL_CACHE = new Map();
async function DOC_src(entry) {
  if (!entry) return '';
  if (entry.dataUrl) return entry.dataUrl;      // legacy inline document
  if (!entry.path || !window.sb) return '';
  const hit = DOC_URL_CACHE.get(entry.path);
  if (hit && hit.until > Date.now()) return hit.url;
  const { data, error } = await sb.storage.from(DOC_BUCKET).createSignedUrl(entry.path, 3600);
  if (error || !data) return '';
  DOC_URL_CACHE.set(entry.path, { url: data.signedUrl, until: Date.now() + 50 * 60 * 1000 });
  return data.signedUrl;
}

// pdf.js only needs the bytes; accept both a data: URL and an https: one.
async function DOC_bytes(src) {
  if (!src) return null;
  if (src.startsWith('data:')) {
    const bin = atob(src.split(',')[1] || '');
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }
  const res = await fetch(src);
  if (!res.ok) throw new Error('fetch-failed');
  return new Uint8Array(await res.arrayBuffer());
}

/* ============ Loading placeholders ============
   A table that quietly swaps its rows a second after it appears reads as a
   glitch; a skeleton says "this is still arriving". Used for the first load
   only — background refreshes keep the real rows on screen. */

function SkeletonBar({ w = '100%', h = 12, className = '' }) {
  return <span className={'block rounded bg-slate-100 animate-pulse ' + className} style={{ width: w, height: h }} />;
}

// `cols` is an array of widths, one per table column.
function SkeletonRows({ rows = 5, cols }) {
  return (
    <>
      {Array.from({ length: rows }).map((_, r) => (
        <tr key={r} className="border-b border-slate-50 last:border-0">
          {cols.map((w, c) => (
            <td key={c} className="px-6 py-5"><SkeletonBar w={w} /></td>
          ))}
        </tr>
      ))}
    </>
  );
}

// Small "refreshing in the background" hint for the header of a live list.
function RefreshingBadge({ on }) {
  if (!on) return null;
  return (
    <span className="inline-flex items-center gap-1.5 text-[11px] font-bold text-slate-400">
      <Lucide.Loader2 size={12} className="animate-spin" /> frissítés…
    </span>
  );
}

/* ============ useApi hook ============ */
function useApi(apiMethod) {
  const [data, setData] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState(null);
  const fetchData = async () => {
    setIsLoading(true);
    try { const result = await apiMethod(); setData(result); }
    catch (err) { setError(err); }
    finally { setIsLoading(false); }
  };
  useEffect(() => { fetchData(); }, []);
  return { data, isLoading, error, setData, refresh: fetchData };
}


/* ===== VideoInterviewSystem ===== */
const VideoInterviewSystem = (() => {
interface VideoInterviewSystemProps {
  onComplete: (videos: VideoInterview[]) => void;
}

const VideoInterviewSystem: React.FC<VideoInterviewSystemProps> = ({ onComplete }) => {
  const [currentStep, setCurrentStep] = useState<'intro' | 'recording' | 'review' | 'completed'>('intro');
  const [currentQuestionIndex, setCurrentQuestionIndex] = useState(0);
  const [isRecording, setIsRecording] = useState(false);
  const [recordedVideos, setRecordedVideos] = useState<VideoInterview[]>([]);
  const [timeLeft, setTimeLeft] = useState(0);
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [recordedBlob, setRecordedBlob] = useState<Blob | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  const videoRef = useRef<HTMLVideoElement>(null);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const timerRef = useRef<NodeJS.Timeout | null>(null);

  const questions = mockDatabase.videoInterviewQuestions;
  const currentQuestion = questions[currentQuestionIndex];

  useEffect(() => {
    if (currentStep === 'recording' || currentStep === 'intro') {
      startCamera();
    } else {
      stopCamera();
    }
    return () => stopCamera();
  }, [currentStep]);

  const startCamera = async () => {
    try {
      const mediaStream = await navigator.mediaDevices.getUserMedia({ 
        video: { width: 1280, height: 720 }, 
        audio: true 
      });
      setStream(mediaStream);
      if (videoRef.current) {
        videoRef.current.srcObject = mediaStream;
      }
    } catch (err) {
      console.error("Error accessing camera:", err);
      alert("Kérjük, engedélyezze a kamera és mikrofon hozzáférést a folytatáshoz.");
    }
  };

  const stopCamera = () => {
    if (stream) {
      stream.getTracks().forEach(track => track.stop());
      setStream(null);
    }
  };

  const startRecording = () => {
    if (!stream) return;

    chunksRef.current = [];
    const mediaRecorder = new MediaRecorder(stream);
    mediaRecorderRef.current = mediaRecorder;

    mediaRecorder.ondataavailable = (e) => {
      if (e.data.size > 0) {
        chunksRef.current.push(e.data);
      }
    };

    mediaRecorder.onstop = () => {
      const blob = new Blob(chunksRef.current, { type: 'video/webm' });
      setRecordedBlob(blob);
      setPreviewUrl(URL.createObjectURL(blob));
      setCurrentStep('review');
    };

    mediaRecorder.start();
    setIsRecording(true);
    setTimeLeft(currentQuestion.durationLimit);

    timerRef.current = setInterval(() => {
      setTimeLeft((prev) => {
        if (prev <= 1) {
          stopRecording();
          return 0;
        }
        return prev - 1;
      });
    }, 1000);
  };

  const stopRecording = () => {
    if (mediaRecorderRef.current && isRecording) {
      mediaRecorderRef.current.stop();
      setIsRecording(false);
      if (timerRef.current) clearInterval(timerRef.current);
    }
  };

  const handleSaveAndNext = () => {
    if (recordedBlob) {
      const newVideo: VideoInterview = {
        id: `V-${Date.now()}`,
        question: currentQuestion.text,
        videoUrl: previewUrl || '',
        duration: `${currentQuestion.durationLimit - timeLeft}s`
      };

      const updatedVideos = [...recordedVideos, newVideo];
      setRecordedVideos(updatedVideos);

      if (currentQuestionIndex < questions.length - 1) {
        setCurrentQuestionIndex(prev => prev + 1);
        setCurrentStep('recording');
        setRecordedBlob(null);
        setPreviewUrl(null);
      } else {
        setCurrentStep('completed');
        onComplete(updatedVideos);
      }
    }
  };

  const handleRetake = () => {
    setRecordedBlob(null);
    setPreviewUrl(null);
    setCurrentStep('recording');
  };

  const renderIntro = () => (
    <div className="flex flex-col items-center justify-center text-center space-y-6 p-8">
      <div className="w-20 h-20 bg-indigo-100 text-indigo-600 rounded-full flex items-center justify-center">
        <ICONS.Video size={40} />
      </div>
      <div>
        <h3 className="text-2xl font-bold text-slate-900">Videó Interjú</h3>
        <p className="text-slate-500 mt-2 max-w-md">
          Ebben a szakaszban 4 rövid kérdésre kell válaszolnia videón keresztül. 
          Kérjük, győződjön meg róla, hogy jól megvilágított helyen van és a mikrofonja megfelelően működik.
        </p>
      </div>
      <div className="bg-amber-50 border border-amber-100 p-4 rounded-xl flex items-start gap-3 text-left max-w-md">
        <ICONS.AlertCircle className="text-amber-500 shrink-0 mt-0.5" size={18} />
        <p className="text-xs text-amber-800">
          Minden kérdésre meghatározott idő áll rendelkezésre. A felvétel automatikusan leáll, ha az idő lejár.
        </p>
      </div>
      <button 
        onClick={() => setCurrentStep('recording')}
        className="bg-indigo-600 text-white px-8 py-3 rounded-xl font-bold hover:bg-indigo-700 transition-all shadow-lg shadow-indigo-100 flex items-center gap-2"
      >
        Interjú megkezdése <ICONS.ArrowRight size={18} />
      </button>
    </div>
  );

  const renderRecording = () => (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="space-y-1">
          <span className="text-[10px] font-bold text-indigo-600 uppercase tracking-widest">
            {currentQuestionIndex + 1} / {questions.length} Kérdés
          </span>
          <h3 className="text-xl font-bold text-slate-900">{currentQuestion.text}</h3>
        </div>
        {isRecording && (
          <div className="flex items-center gap-2 bg-red-50 text-red-600 px-4 py-2 rounded-full font-mono font-bold animate-pulse">
            <div className="w-2 h-2 bg-red-600 rounded-full" />
            00:{timeLeft < 10 ? `0${timeLeft}` : timeLeft}
          </div>
        )}
      </div>

      <div className="relative aspect-video bg-slate-900 rounded-3xl overflow-hidden shadow-2xl border-4 border-white">
        <video 
          ref={videoRef} 
          autoPlay 
          muted 
          playsInline 
          className="w-full h-full object-cover mirror"
        />
        
        {!isRecording && (
          <div className="absolute inset-0 bg-black/40 backdrop-blur-sm flex items-center justify-center">
            <button 
              onClick={startRecording}
              className="w-20 h-20 bg-white text-indigo-600 rounded-full flex items-center justify-center hover:scale-110 transition-all shadow-xl"
            >
              <ICONS.Play size={32} fill="currentColor" />
            </button>
          </div>
        )}

        {isRecording && (
          <div className="absolute bottom-6 left-1/2 -translate-x-1/2">
            <button 
              onClick={stopRecording}
              className="bg-white text-red-600 px-6 py-3 rounded-full font-bold flex items-center gap-2 shadow-xl hover:bg-red-50 transition-all"
            >
              <div className="w-3 h-3 bg-red-600 rounded-sm" /> Felvétel leállítása
            </button>
          </div>
        )}
      </div>
    </div>
  );

  const renderReview = () => (
    <div className="space-y-6">
      <div className="space-y-1">
        <h3 className="text-xl font-bold text-slate-900">Ellenőrizze a választ</h3>
        <p className="text-sm text-slate-500">Visszanézheti a felvételt, mielőtt továbblépne a következő kérdésre.</p>
      </div>

      <div className="relative aspect-video bg-slate-900 rounded-3xl overflow-hidden shadow-2xl border-4 border-white">
        <video 
          src={previewUrl || ''} 
          controls 
          className="w-full h-full object-cover"
        />
      </div>

      <div className="flex items-center justify-between gap-4">
        <button 
          onClick={handleRetake}
          className="flex-1 border-2 border-slate-200 text-slate-600 py-4 rounded-2xl font-bold hover:bg-slate-50 transition-all flex items-center justify-center gap-2"
        >
          <ICONS.RotateCcw size={18} /> Új felvétel
        </button>
        <button 
          onClick={handleSaveAndNext}
          className="flex-1 bg-indigo-600 text-white py-4 rounded-2xl font-bold hover:bg-indigo-700 transition-all shadow-lg shadow-indigo-100 flex items-center justify-center gap-2"
        >
          {currentQuestionIndex < questions.length - 1 ? 'Következő kérdés' : 'Interjú befejezése'} <ICONS.ArrowRight size={18} />
        </button>
      </div>
    </div>
  );

  const renderCompleted = () => (
    <div className="flex flex-col items-center justify-center text-center space-y-6 p-8">
      <div className="w-20 h-20 bg-emerald-100 text-emerald-600 rounded-full flex items-center justify-center">
        <ICONS.CheckCircle size={40} />
      </div>
      <div>
        <h3 className="text-2xl font-bold text-slate-900">Gratulálunk!</h3>
        <p className="text-slate-500 mt-2 max-w-md">
          Sikeresen befejezte a videó interjút. Válaszait elmentettük és a felvételi bizottság hamarosan értékeli őket.
        </p>
      </div>
      <div className="grid grid-cols-2 gap-4 w-full max-w-md">
        {recordedVideos.map((video, idx) => (
          <div key={video.id} className="bg-white p-3 rounded-xl border border-slate-100 flex items-center gap-3">
            <div className="w-8 h-8 bg-slate-100 rounded-lg flex items-center justify-center text-xs font-bold text-slate-500">
              {idx + 1}
            </div>
            <div className="text-left">
              <p className="text-[10px] font-bold text-slate-400 uppercase">Kérdés</p>
              <p className="text-xs font-bold text-slate-700 truncate w-32">{video.question}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );

  return (
    <div className="max-w-3xl mx-auto bg-white rounded-[40px] shadow-xl border border-slate-100 overflow-hidden">
      <div className="p-8 md:p-12">
        <AnimatePresence mode="wait">
          <motion.div
            key={currentStep}
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -20 }}
            transition={{ duration: 0.3 }}
          >
            {currentStep === 'intro' && renderIntro()}
            {currentStep === 'recording' && renderRecording()}
            {currentStep === 'review' && renderReview()}
            {currentStep === 'completed' && renderCompleted()}
          </motion.div>
        </AnimatePresence>
      </div>
      
      {currentStep !== 'completed' && (
        <div className="bg-slate-50 px-8 py-4 flex items-center justify-between border-t border-slate-100">
          <div className="flex items-center gap-2">
            <div className={`w-2 h-2 rounded-full ${stream ? 'bg-emerald-500' : 'bg-red-500'}`} />
            <span className="text-[10px] font-bold text-slate-500 uppercase tracking-wider">
              Kamera: {stream ? 'Aktív' : 'Nincs kapcsolat'}
            </span>
          </div>
          <div className="flex gap-1">
            {questions.map((_, idx) => (
              <div 
                key={idx} 
                className={`h-1 w-8 rounded-full transition-all ${
                  idx < currentQuestionIndex ? 'bg-indigo-600' : 
                  idx === currentQuestionIndex ? 'bg-indigo-400' : 'bg-slate-200'
                }`} 
              />
            ))}
          </div>
        </div>
      )}

      <style>{`
        .mirror {
          transform: scaleX(-1);
        }
      `}</style>
    </div>
  );
};
return VideoInterviewSystem;
})();

/* ===== Sidebar ===== */
const Sidebar = (() => {
interface SidebarProps {
  activeView: AppView;
  setActiveView: (view: AppView) => void;
  currentUser: User;
  onLogout: () => void;
  menuItems: any[];
}

const Sidebar: React.FC<SidebarProps> = ({ 
  activeView, 
  setActiveView, 
  currentUser, 
  onLogout,
  onOpenProfile,
  menuItems 
}) => {
  return (
    <aside className="w-72 h-screen bg-primary flex flex-col fixed left-0 top-0 z-[60] shadow-2xl">
      <div className="p-8 border-b border-white/10">
        <div className="flex flex-col gap-3">
          <div className="flex items-center gap-2.5">
            <span className="font-black text-2xl text-white tracking-tight leading-none">UniPortal</span>
            <span className="text-[10px] font-black tracking-[0.15em] text-primary bg-white px-1.5 py-1 rounded">PRO</span>
          </div>
          <div>
            <p className="text-[10px] text-white/80 font-black uppercase tracking-widest">Neumann János Egyetem</p>
          </div>
        </div>
      </div>

      <nav className="flex-1 p-4 mt-4 space-y-1 overflow-y-auto custom-scrollbar">
        {menuItems.map((item) => (
          <button
            key={item.id}
            onClick={() => setActiveView(item.id)}
            className={`w-full flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 group ${
              activeView === item.id
                ? 'bg-white/20 text-white shadow-sm'
                : 'text-white/70 hover:bg-white/10 hover:text-white'
            }`}
          >
            <span className={`${activeView === item.id ? 'text-white' : 'text-white/50 group-hover:text-white'}`}>
              {item.icon}
            </span>
            <span className="font-bold text-xs uppercase tracking-tight">{item.label}</span>
          </button>
        ))}
        <button
          onClick={onOpenProfile}
          className="w-full flex items-center gap-3 px-4 py-3 rounded-xl transition-all duration-200 group text-white/70 hover:bg-white/10 hover:text-white"
        >
          <span className="text-white/50 group-hover:text-white"><ICONS.UserCircle size={20} /></span>
          <span className="font-bold text-xs uppercase tracking-tight">Profilom</span>
        </button>
      </nav>

      <div className="p-6 border-t border-white/10">
        <div className="flex items-center gap-3 p-3 rounded-2xl bg-white/10 border border-white/5">
          <button onClick={onOpenProfile} className="flex items-center gap-3 flex-1 min-w-0 text-left hover:opacity-90 transition-opacity" title="Profilom megnyitása">
            <div className="w-10 h-10 rounded-xl bg-white/20 overflow-hidden shadow-sm flex-none">
              <img src={currentUser.avatar} alt="Avatar" className="w-full h-full object-cover" />
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-xs font-black text-white truncate">{currentUser.name}</p>
              <p className="text-[10px] text-white/60 truncate font-bold uppercase tracking-tighter">{currentUser.role}</p>
            </div>
          </button>
          <button 
            onClick={onLogout}
            className="text-white/40 hover:text-white transition-colors p-1"
          >
            <ICONS.LogOut size={16} />
          </button>
        </div>
      </div>
    </aside>
  );
};
return Sidebar;
})();

/* ===== AgentPortal ===== */
const AgentPortal = (() => {
const mockResources: Resource[] = [
  { id: 'R1', title: 'Egyetemi Brosúra 2024', type: 'PDF', size: '4.2 MB' },
  { id: 'R2', title: 'Hivatalos Logo Készlet', type: 'Logo', size: '15.8 MB' },
  { id: 'R3', title: 'Kampusz Galéria', type: 'Image', size: '120 MB' },
];

interface AgentPortalProps {
  user: User;
}

const AgentPortal: React.FC<AgentPortalProps> = ({ user }) => {
  const isAgent = user.role === 'AGENT';
  const [activeTab, setActiveTab] = useState<'overview' | 'students' | 'commission' | 'hierarchy' | 'resources' | 'agencies'>(isAgent ? 'overview' : 'overview');
  const [searchTerm, setSearchTerm] = useState('');
  const [students, setStudents] = useState<Student[]>([]);
  const [agencies, setAgencies] = useState<Agency[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  
  // ... existing state ...
  const [isAddingAgency, setIsAddingAgency] = useState(false);
  const [editingAgencyId, setEditingAgencyId] = useState<string | null>(null);
  const [newAgency, setNewAgency] = useState<Partial<Agency>>({ name: '', commissionRate: 0, contactPerson: '', email: '', status: 'Active' });
  const [editAgencyData, setEditAgencyData] = useState<Partial<Agency>>({});

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [studentData, agencyData] = await Promise.all([
          api.getStudents(),
          api.getAgencies()
        ]);
        
        if (isAgent && user.agencyId) {
          setStudents(studentData.filter(s => s.agencyId === user.agencyId));
          setAgencies(agencyData.filter(a => a.id === user.agencyId));
        } else {
          setStudents(studentData);
          setAgencies(agencyData);
        }
      } catch (error) {
        console.error('Failed to fetch data:', error);
      } finally {
        setIsLoading(false);
      }
    };
    fetchData();
  }, [isAgent, user.agencyId]);

  const myAgency = isAgent ? agencies.find(a => a.id === user.agencyId) : null;

  const handleAddAgency = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      const added = await api.addAgency(newAgency);
      setAgencies([...agencies, added]);
      setIsAddingAgency(false);
      setNewAgency({ name: '', commissionRate: 0, contactPerson: '', email: '', status: 'Active' });
    } catch (error) {
      console.error('Failed to add agency:', error);
    }
  };

  const handleAssignAgency = async (studentId: string, agencyId: string) => {
    try {
      const updated = await api.updateStudent(studentId, { agencyId });
      setStudents(students.map(s => s.id === studentId ? updated : s));
    } catch (error) {
      console.error('Failed to assign agency:', error);
    }
  };

  const handleEditAgency = (agency: Agency) => {
    setEditingAgencyId(agency.id);
    setEditAgencyData(agency);
  };

  const handleUpdateAgency = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingAgencyId) return;
    try {
      const updated = await api.updateAgency(editingAgencyId, editAgencyData);
      setAgencies(agencies.map(a => a.id === editingAgencyId ? updated : a));
      setEditingAgencyId(null);
    } catch (error) {
      console.error('Failed to update agency:', error);
    }
  };
  
  const calculateCommission = (studentList: Student[], isPaidOnly: boolean) => {
    return studentList
      .filter(s => isPaidOnly ? s.status === 'Paid' : (s.status === 'Accepted' || s.status === 'Submitted'))
      .reduce((acc, s) => {
        const agency = agencies.find(a => a.id === s.agencyId);
        const rate = agency ? agency.commissionRate : 0;
        return acc + (s.tuitionFee * (rate / 100));
      }, 0);
  };

  const stats = {
    totalStudents: students.length,
    pendingApps: students.filter(s => s.status === 'Submitted' || s.status === 'Missing Info').length,
    commissionTotal: calculateCommission(students, true),
  };

  const commissions: Commission = {
    payable: stats.commissionTotal,
    pending: calculateCommission(students, false),
    paid: 0, // In a real app, this would come from a 'payouts' table
  };

  const contracts: Contract[] = [
    { id: 'C1', title: 'Main Agent Agreement 2024', expiryDate: '2025.12.31', status: 'Active' },
    { id: 'C2', title: 'Regional Partnership - DACH', expiryDate: '2024.05.15', status: 'Expiring Soon' },
  ];

  const [selectedAgencyFilter, setSelectedAgencyFilter] = useState<string>('All');

  const filteredStudents = students.filter(s => {
    const matchesSearch = s.name.toLowerCase().includes(searchTerm.toLowerCase()) || 
                         s.program.toLowerCase().includes(searchTerm.toLowerCase());
    const matchesAgency = selectedAgencyFilter === 'All' || 
                         (selectedAgencyFilter === 'Individual' && !s.agencyId) ||
                         s.agencyId === selectedAgencyFilter;
    return matchesSearch && matchesAgency;
  });

  const renderOverview = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100">
          <p className="text-slate-400 text-sm font-medium uppercase tracking-wider mb-2">Összes Diák</p>
          <div className="flex items-end justify-between">
            <h3 className="text-3xl font-bold text-slate-800">{stats.totalStudents}</h3>
            <span className="text-emerald-500 text-sm font-semibold bg-emerald-50 px-2 py-1 rounded-lg">Aktív</span>
          </div>
        </div>
        <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100">
          <p className="text-slate-400 text-sm font-medium uppercase tracking-wider mb-2">Függő Jelentkezések</p>
          <div className="flex items-end justify-between">
            <h3 className="text-3xl font-bold text-slate-800">{stats.pendingApps}</h3>
            <span className="text-amber-500 text-sm font-semibold bg-amber-50 px-2 py-1 rounded-lg">Folyamatban</span>
          </div>
        </div>
        <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100">
          <p className="text-slate-400 text-sm font-medium uppercase tracking-wider mb-2">Várható Jutalék</p>
          <div className="flex items-end justify-between">
            <h3 className="text-3xl font-bold text-slate-800">€{stats.commissionTotal.toLocaleString()}</h3>
            <div className="w-10 h-10 bg-amber-50 text-amber-500 rounded-full flex items-center justify-center">
              <ICONS.Wallet size={20} />
            </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100">
          <div className="flex items-center justify-between mb-6">
            <h4 className="font-bold text-slate-800 text-lg">Legutóbbi Jelentkezők</h4>
            <button 
              onClick={() => setActiveTab('students')}
              className="text-indigo-600 text-sm font-semibold hover:underline"
            >
              Összes megtekintése
            </button>
          </div>
          <div className="space-y-4">
            {students.slice(0, 5).map(student => (
              <div key={student.id} className="flex items-center justify-between p-4 hover:bg-slate-50 rounded-xl transition-colors border border-transparent hover:border-slate-100">
                <div className="flex items-center gap-4">
                  <div className="w-10 h-10 rounded-full bg-indigo-50 text-indigo-600 flex items-center justify-center font-bold">
                    {student.name.charAt(0)}
                  </div>
                  <div>
                    <p className="font-semibold text-slate-800">{student.name}</p>
                    <p className="text-xs text-slate-400">{student.program}</p>
                  </div>
                </div>
                <div className="text-right">
                  <span className={`px-2 py-1 rounded-md text-[10px] font-bold uppercase ${
                    student.status === 'Paid' ? 'bg-emerald-50 text-emerald-600' : 
                    student.status === 'Accepted' ? 'bg-blue-50 text-blue-600' : 
                    student.status === 'Missing Info' ? 'bg-amber-50 text-amber-600' : 'bg-slate-100 text-slate-500'
                  }`}>
                    {student.status}
                  </span>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100">
          <h4 className="font-bold text-slate-800 text-lg mb-6">Szerződéskezelés</h4>
          <div className="space-y-4">
            {contracts.map(contract => (
              <div key={contract.id} className="p-4 border border-slate-100 rounded-xl relative overflow-hidden group">
                <div className={`absolute top-0 left-0 bottom-0 w-1 ${contract.status === 'Active' ? 'bg-emerald-500' : 'bg-amber-500'}`} />
                <div className="flex items-center justify-between">
                  <div>
                    <p className="font-semibold text-slate-800">{contract.title}</p>
                    <div className="flex items-center gap-2 mt-1">
                      <ICONS.Clock size={12} className="text-slate-400" />
                      <p className="text-xs text-slate-400">Lejárat: {contract.expiryDate}</p>
                    </div>
                  </div>
                  <ICONS.FileText className="text-slate-300 group-hover:text-indigo-400 transition-colors" size={24} />
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );

  const renderStudentsList = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50 flex flex-col md:flex-row md:items-center justify-between gap-4">
          <div className="flex items-center gap-4">
            <h3 className="font-bold text-slate-800 text-lg">Diák Jelentkezések ({filteredStudents.length})</h3>
            {!isAgent && (
              <select 
                value={selectedAgencyFilter}
                onChange={(e) => setSelectedAgencyFilter(e.target.value)}
                className="text-xs bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
              >
                <option value="All">Minden forrás</option>
                <option value="Individual">Egyéni jelentkezők</option>
                {agencies.map(a => (
                  <option key={a.id} value={a.id}>{a.name}</option>
                ))}
              </select>
            )}
          </div>
          <div className="relative w-full md:w-64">
            <ICONS.Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
            <input 
              type="text" 
              placeholder="Név vagy szak..." 
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="w-full pl-10 pr-4 py-2 bg-slate-50 border border-slate-100 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
            />
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Diák adatai</th>
                <th className="px-6 py-4">Program</th>
                <th className="px-6 py-4">Ügynökség</th>
                <th className="px-6 py-4">Státusz</th>
                <th className="px-6 py-4 text-right">Művelet</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {filteredStudents.map(student => (
                <tr key={student.id} className="hover:bg-slate-50 transition-colors group">
                  <td className="px-6 py-4">
                    <div className="flex items-center gap-3">
                      <div className="w-8 h-8 rounded-full bg-slate-100 flex items-center justify-center text-xs font-bold text-slate-500">
                        {student.name.charAt(0)}
                      </div>
                      <div>
                        <p className="font-bold text-slate-800 text-sm">{student.name}</p>
                        <p className="text-[10px] text-slate-400">{student.email}</p>
                      </div>
                    </div>
                  </td>
                  <td className="px-6 py-4 text-sm text-slate-600">{student.program}</td>
                  <td className="px-6 py-4">
                    {isAgent ? (
                      <span className="text-xs font-medium text-slate-600">{myAgency?.name}</span>
                    ) : (
                      <select 
                        value={student.agencyId || ''} 
                        onChange={(e) => handleAssignAgency(student.id, e.target.value)}
                        className="text-xs bg-slate-50 border border-slate-100 rounded px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                      >
                        <option value="">Egyéni jelentkező</option>
                        {agencies.map(a => (
                          <option key={a.id} value={a.id}>{a.name}</option>
                        ))}
                      </select>
                    )}
                  </td>
                  <td className="px-6 py-4">
                    <span className={`px-2 py-1 rounded-md text-[10px] font-bold uppercase ${
                      student.status === 'Paid' ? 'bg-emerald-50 text-emerald-600' : 
                      student.status === 'Accepted' ? 'bg-blue-50 text-blue-600' : 
                      student.status === 'Missing Info' ? 'bg-amber-50 text-amber-600' : 
                      student.status === 'Submitted' ? 'bg-indigo-50 text-indigo-600' : 'bg-slate-100 text-slate-500'
                    }`}>
                      {student.status}
                    </span>
                  </td>
                  <td className="px-6 py-4 text-right">
                    <button className="p-2 text-slate-400 hover:text-indigo-600 bg-white border border-slate-100 rounded-lg shadow-sm">
                      <ICONS.Eye size={16} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  const renderCommission = () => {
    const paidStudents = students.filter(s => s.status === 'Paid');
    const totalCalculatedCommission = paidStudents.reduce((acc, s) => {
      const agency = agencies.find(a => a.id === s.agencyId);
      const rate = agency ? agency.commissionRate : 0;
      return acc + (s.tuitionFee * (rate / 100));
    }, 0);

    return (
      <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="bg-indigo-900 rounded-3xl p-8 text-white relative overflow-hidden shadow-2xl shadow-indigo-200">
          <div className="absolute top-0 right-0 p-12 opacity-10">
            <ICONS.Wallet size={180} />
          </div>
          <div className="relative z-10">
            <p className="text-indigo-200 text-sm font-medium uppercase tracking-widest mb-2">Commission Wallet (Kalkulált)</p>
            <h2 className="text-5xl font-bold mb-8">€{totalCalculatedCommission.toLocaleString()}</h2>
            <div className="grid grid-cols-2 gap-8 max-w-md">
              <div>
                <p className="text-indigo-300 text-xs mb-1">Várható (Függő)</p>
                <p className="text-xl font-semibold">€{commissions.pending.toLocaleString()}</p>
              </div>
              <div>
                <p className="text-indigo-300 text-xs mb-1">Már kifizetve</p>
                <p className="text-xl font-semibold">€{commissions.paid.toLocaleString()}</p>
              </div>
            </div>
            <button className="mt-8 bg-white text-indigo-900 px-6 py-3 rounded-xl font-bold hover:bg-indigo-50 transition-colors shadow-lg">
              Kifizetés igénylése
            </button>
          </div>
        </div>
        
        <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
          <div className="p-6 border-b border-slate-50">
            <h3 className="font-bold text-slate-800 text-lg">Jutalék Előzmények (Ügynökségi Kulcsok Alapján)</h3>
          </div>
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Diák / Időpont</th>
                <th className="px-6 py-4">Ügynökség</th>
                <th className="px-6 py-4">Tandíj</th>
                <th className="px-6 py-4">Jutalék %</th>
                <th className="px-6 py-4">Összeg</th>
                <th className="px-6 py-4 text-right">Státusz</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {paidStudents.map((s) => {
                const agency = agencies.find(a => a.id === s.agencyId);
                const rate = agency ? agency.commissionRate : 0;
                const amount = s.tuitionFee * (rate / 100);
                return (
                  <tr key={s.id} className="hover:bg-slate-50 transition-colors">
                    <td className="px-6 py-4">
                      <p className="font-semibold text-slate-800">{s.name}</p>
                      <p className="text-xs text-slate-400">{s.appliedAt}</p>
                    </td>
                    <td className="px-6 py-4 text-xs font-medium text-slate-600">
                      {agency ? agency.name : <span className="text-slate-300 italic">Egyéni</span>}
                    </td>
                    <td className="px-6 py-4 text-slate-600">€{s.tuitionFee.toLocaleString()}</td>
                    <td className="px-6 py-4 text-slate-600">{rate}%</td>
                    <td className="px-6 py-4 font-bold text-slate-800">€{amount.toLocaleString()}</td>
                    <td className="px-6 py-4 text-right">
                      <span className="px-2 py-1 bg-emerald-50 text-emerald-600 rounded text-[10px] font-bold uppercase">Ready</span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    );
  };

  const renderAgencies = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex justify-between items-center">
        <h3 className="text-xl font-bold text-slate-800">Ügynökségek Kezelése</h3>
        <button 
          onClick={() => setIsAddingAgency(true)}
          className="bg-indigo-600 text-white px-4 py-2 rounded-xl text-sm font-bold hover:bg-indigo-700 transition-all flex items-center gap-2"
        >
          <ICONS.PlusCircle size={18} /> Új Ügynökség
        </button>
      </div>

      {isAddingAgency && (
        <div className="bg-white p-6 rounded-2xl border border-indigo-100 shadow-md animate-in zoom-in-95 duration-200">
          <form onSubmit={handleAddAgency} className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <div>
              <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Név</label>
              <input 
                type="text" 
                value={newAgency.name}
                onChange={e => setNewAgency({...newAgency, name: e.target.value})}
                className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                required
              />
            </div>
            <div>
              <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Jutalék Kulcs (%)</label>
              <input 
                type="number" 
                value={newAgency.commissionRate}
                onChange={e => setNewAgency({...newAgency, commissionRate: Number(e.target.value)})}
                className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                required
              />
            </div>
            <div>
              <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Kapcsolattartó</label>
              <input 
                type="text" 
                value={newAgency.contactPerson}
                onChange={e => setNewAgency({...newAgency, contactPerson: e.target.value})}
                className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
              />
            </div>
            <div>
              <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Email</label>
              <input 
                type="email" 
                value={newAgency.email}
                onChange={e => setNewAgency({...newAgency, email: e.target.value})}
                className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
              />
            </div>
            <div className="md:col-span-2 lg:col-span-3 flex justify-end gap-2 mt-2">
              <button 
                type="button"
                onClick={() => setIsAddingAgency(false)}
                className="px-4 py-2 text-slate-500 font-bold text-sm hover:bg-slate-50 rounded-lg"
              >
                Mégse
              </button>
              <button 
                type="submit"
                className="bg-indigo-600 text-white px-6 py-2 rounded-lg text-sm font-bold hover:bg-indigo-700"
              >
                Mentés
              </button>
            </div>
          </form>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {agencies.map(agency => (
          <div key={agency.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all">
            {editingAgencyId === agency.id ? (
              <form onSubmit={handleUpdateAgency} className="space-y-4">
                <div>
                  <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Név</label>
                  <input 
                    type="text" 
                    value={editAgencyData.name}
                    onChange={e => setEditAgencyData({...editAgencyData, name: e.target.value})}
                    className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                    required
                  />
                </div>
                <div>
                  <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Jutalék Kulcs (%)</label>
                  <input 
                    type="number" 
                    value={editAgencyData.commissionRate}
                    onChange={e => setEditAgencyData({...editAgencyData, commissionRate: Number(e.target.value)})}
                    className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                    required
                  />
                </div>
                <div>
                  <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Kapcsolattartó</label>
                  <input 
                    type="text" 
                    value={editAgencyData.contactPerson}
                    onChange={e => setEditAgencyData({...editAgencyData, contactPerson: e.target.value})}
                    className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                  />
                </div>
                <div>
                  <label className="text-[10px] font-bold text-slate-400 uppercase mb-1 block">Email</label>
                  <input 
                    type="email" 
                    value={editAgencyData.email}
                    onChange={e => setEditAgencyData({...editAgencyData, email: e.target.value})}
                    className="w-full bg-slate-50 border border-slate-100 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                  />
                </div>
                <div className="flex justify-end gap-2 pt-2">
                  <button 
                    type="button"
                    onClick={() => setEditingAgencyId(null)}
                    className="px-3 py-1.5 text-slate-500 font-bold text-xs hover:bg-slate-50 rounded-lg"
                  >
                    Mégse
                  </button>
                  <button 
                    type="submit"
                    className="bg-indigo-600 text-white px-4 py-1.5 rounded-lg text-xs font-bold hover:bg-indigo-700"
                  >
                    Mentés
                  </button>
                </div>
              </form>
            ) : (
              <>
                <div className="flex justify-between items-start mb-4">
                  <div className="w-10 h-10 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center">
                    <ICONS.Briefcase size={20} />
                  </div>
                  <span className="bg-emerald-50 text-emerald-600 text-[10px] font-bold px-2 py-1 rounded uppercase">
                    {agency.commissionRate}% Jutalék
                  </span>
                </div>
                <h4 className="font-bold text-slate-800 text-lg mb-1">{agency.name}</h4>
                <p className="text-xs text-slate-400 mb-4">{agency.contactPerson} • {agency.email}</p>
                <div className="pt-4 border-t border-slate-50 flex justify-between items-center">
                  <span className="text-[10px] font-bold text-slate-400 uppercase">Státusz: {agency.status}</span>
                  <button 
                    onClick={() => handleEditAgency(agency)}
                    className="text-indigo-600 text-xs font-bold hover:underline"
                  >
                    Szerkesztés
                  </button>
                </div>
              </>
            )}
          </div>
        ))}
      </div>
    </div>
  );

  const renderResources = () => (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {mockResources.map(resource => (
        <div key={resource.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all group">
          <div className="w-12 h-12 bg-slate-100 rounded-xl flex items-center justify-center text-slate-400 mb-4 group-hover:bg-indigo-50 group-hover:text-indigo-500 transition-colors">
            <ICONS.FileText size={24} />
          </div>
          <h4 className="font-bold text-slate-800 mb-1">{resource.title}</h4>
          <div className="flex items-center gap-2 mb-6 text-xs text-slate-400">
            <span>{resource.type}</span>
            <span>•</span>
            <span>{resource.size}</span>
          </div>
          <button className="w-full flex items-center justify-center gap-2 py-3 bg-slate-50 text-slate-600 rounded-xl font-semibold hover:bg-indigo-600 hover:text-white transition-all">
            <ICONS.Download size={18} />
            Letöltés
          </button>
        </div>
      ))}
    </div>
  );

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-96">
        <div className="w-10 h-10 border-4 border-indigo-500 border-t-transparent rounded-full animate-spin"></div>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Portal Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">
            {isAgent ? `Ügynöki Portál: ${myAgency?.name || 'Betöltés...'}` : 'Ügynök és partner portál'}
          </h2>
          <p className="text-slate-500 mt-1">
            {isAgent 
              ? `Üdvözöljük, ${user.name}! Kövesse nyomon ügynöksége teljesítményét és diákjait.` 
              : 'Üdvözöljük a Global Study Ügynökség központi vezérlőpultján.'}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <button className="flex items-center gap-2 bg-indigo-600 text-white px-6 py-3 rounded-xl font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all transform hover:-translate-y-0.5 active:translate-y-0">
            <ICONS.PlusCircle size={20} />
            Új jelentkezés indítása
          </button>
        </div>
      </div>

      {/* Internal Navigation Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveTab('overview')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'overview' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Áttekintés
        </button>
        <button 
          onClick={() => setActiveTab('students')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'students' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Diákok
        </button>
        <button 
          onClick={() => setActiveTab('commission')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'commission' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Commission Wallet
        </button>
        {!isAgent && (
          <>
            <button 
              onClick={() => setActiveTab('agencies')}
              className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'agencies' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
            >
              Ügynökségek
            </button>
            <button 
              onClick={() => setActiveTab('hierarchy')}
              className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'hierarchy' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
            >
              Hiearchia & Al-ügynökök
            </button>
          </>
        )}
        <button 
          onClick={() => setActiveTab('resources')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'resources' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Resource Library
        </button>
      </div>

      {/* Dynamic Content Area */}
      <div className="mt-8">
        {activeTab === 'overview' && renderOverview()}
        {activeTab === 'students' && renderStudentsList()}
        {activeTab === 'commission' && renderCommission()}
        {activeTab === 'agencies' && renderAgencies()}
        {activeTab === 'resources' && renderResources()}
        {activeTab === 'hierarchy' && (
          <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
            <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden">
              <div className="p-6 border-b border-slate-50">
                <h3 className="font-bold text-slate-800 text-lg">Ügynökségi Hierarchia és Teljesítmény</h3>
              </div>
              <div className="p-6">
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                  {agencies.map(agency => {
                    const agencyStudents = students.filter(s => s.agencyId === agency.id);
                    const paidCount = agencyStudents.filter(s => s.status === 'Paid').length;
                    const conversionRate = agencyStudents.length > 0 ? (paidCount / agencyStudents.length * 100).toFixed(1) : 0;
                    
                    return (
                      <div key={agency.id} className="p-5 border border-slate-100 rounded-2xl hover:border-indigo-200 transition-colors">
                        <div className="flex items-center justify-between mb-4">
                          <div className="flex items-center gap-3">
                            <div className="w-10 h-10 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center font-bold">
                              {agency.name.charAt(0)}
                            </div>
                            <div>
                              <p className="font-bold text-slate-800">{agency.name}</p>
                              <p className="text-[10px] text-slate-400 uppercase font-bold tracking-wider">{agency.contactPerson}</p>
                            </div>
                          </div>
                          <span className="text-xs font-bold text-indigo-600 bg-indigo-50 px-2 py-1 rounded-lg">
                            {agency.commissionRate}%
                          </span>
                        </div>
                        <div className="grid grid-cols-2 gap-4 pt-4 border-t border-slate-50">
                          <div>
                            <p className="text-[10px] text-slate-400 font-bold uppercase">Diákok</p>
                            <p className="text-lg font-bold text-slate-800">{agencyStudents.length}</p>
                          </div>
                          <div>
                            <p className="text-[10px] text-slate-400 font-bold uppercase">Konverzió</p>
                            <p className="text-lg font-bold text-emerald-600">{conversionRate}%</p>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
return AgentPortal;
})();

/* ===== AdmissionsCore ===== */
const AdmissionsCore = (() => {
type SubView = 'applications' | 'form_builder' | 'review' | 'offers';

const AdmissionsCore = ({ user }) => {
  const [activeSubView, setActiveSubView] = useState<SubView>('applications');
  const [isScanning, setIsScanning] = useState(false);
  const [students, setStudents] = useState<Student[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
  const [journeyProcs, setJourneyProcs] = useState([]);
  const [procsLoading, setProcsLoading] = useState(true);      // first load — show a skeleton
  const [procsRefreshing, setProcsRefreshing] = useState(false); // poll/realtime — keep the table
  const [detailProc, setDetailProc] = useState(null);
  const [detailFull, setDetailFull] = useState(null);
  const [thread, setThread] = useState([]);
  useEffect(() => {
    if (!detailFull) { setThread([]); return; }
    const owner = detailFull._owner || 'demo';
    let arr = [];
    try { const v = JSON.parse(localStorage.getItem('nje_messages_' + owner)); if (Array.isArray(v)) arr = v; } catch (e) {}
    setThread(arr.filter(m => m.processId === detailFull.id).reverse());
    (async () => {
      const remote = await spFetchMsgs(owner);
      if (!remote) return;
      const mine = remote.filter(m => m.processId === detailFull.id);
      if (mine.length) setThread(prev => { const byId = {}; prev.forEach(m => byId[m.id] = m); mine.forEach(m => byId[m.id] = m); return Object.values(byId).sort((a, b) => (a.date || '').localeCompare(b.date || '')); });
    })();
  }, [detailFull && detailFull.id]);
  const [previewDoc, setPreviewDoc] = useState(null);
  const [aiReport, setAiReport] = useState(null);
  const [msgDraft, setMsgDraft] = useState({ subject: '', body: '', attachments: [] });
  const [msgSent, setMsgSent] = useState(false);

  useEffect(() => {
    // Demo mintaadat kizárólag az admin nézethez, külön 'demo' kulcsban (sosem kerül diák székébe).
    try { if (!localStorage.getItem('nje_processes_demo') && JourneyShared.seedProcesses) localStorage.setItem('nje_processes_demo', JSON.stringify(JourneyShared.seedProcesses())); } catch (e) {}
    const out = [];
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.indexOf('nje_processes_') === 0) {
          try { const arr = JSON.parse(localStorage.getItem(k)); if (Array.isArray(arr)) arr.forEach(p => out.push({ ...p, _owner: k.replace('nje_processes_', '') })); } catch (e) {}
        }
      }
    } catch (e) {}
    setJourneyProcs(out.length ? out : (JourneyShared.seedProcesses ? JourneyShared.seedProcesses().map(p => ({ ...p, _owner: 'demo' })) : []));
    // Megosztott (Supabase) folyamatok + automatikus frissítés (realtime + lekérdezés).
    let alive = true;
    // `first` distinguishes the initial load (show a skeleton — the local seed
    // underneath it is not the real list yet) from a background refresh (keep
    // the table on screen, just mark it as refreshing).
    const refetch = async (first) => {
      if (!alive) return;
      if (first) setProcsLoading(true); else setProcsRefreshing(true);
      const remote = await spFetchProcs(null);
      if (!alive) return;
      if (remote && remote.length) {
        setJourneyProcs(prev => {
          const byId = {}; prev.forEach(p => { byId[p.id] = p; }); remote.forEach(p => { byId[p.id] = p; });
          return Object.values(byId);
        });
      }
      setProcsLoading(false); setProcsRefreshing(false);
    };
    refetch(true);
    // Realtime (migration 04) already pushes every change, so this is only a
      // safety net for a dropped websocket — 12 s meant a needless round-trip
      // five times a minute for every open tab.
      const poll = setInterval(refetch, 60000);
    let channel = null;
    try {
      if (window.sb && sb.channel) {
        channel = sb.channel('ap_admin').on('postgres_changes', { event: '*', schema: 'public', table: 'admission_processes' }, refetch).subscribe();
      }
    } catch (e) {}
    return () => { alive = false; clearInterval(poll); try { if (channel) sb.removeChannel(channel); } catch (e) {} };
  }, [activeSubView]);

  useEffect(() => {
    const fetchStudents = async () => {
      try {
        const data = await api.getStudents();
        setStudents(data);
        if (data.length > 0 && !selectedStudentId) {
          setSelectedStudentId(data[0].id);
        }
      } catch (error) {
        console.error('Failed to fetch students:', error);
      } finally {
        setIsLoading(false);
      }
    };
    fetchStudents();
  }, []);

  const selectedStudent = students.find(s => s.id === selectedStudentId);

  const simulateScan = () => {
    setIsScanning(true);
    setTimeout(() => setIsScanning(false), 2000);
  };

  const handleSendConditional = async (studentId: string) => {
    try {
      const updated = await api.sendConditionalAdmission(studentId);
      setStudents(students.map(s => s.id === studentId ? updated : s));
    } catch (error) {
      console.error('Failed to send conditional admission:', error);
    }
  };

  const renderApplications = () => {
    const SD = JourneyShared.STEP_DEFS || [];
    const DT = JourneyShared.DOC_TYPES || [];
    const PROGS = JourneyShared.PROGRAMS || [];
    const reqDocs = DT.filter(d => !d.optional);
    const pName = (p) => (p.data && p.data.extracted && p.data.extracted.name) || (p.data && p.data.account && p.data.account.fullName) || 'Új jelentkező';
    const sendMessage = (proc) => {
      const owner = proc._owner || 'demo';
      const key = 'nje_messages_' + owner;
      let arr = [];
      try { const v = JSON.parse(localStorage.getItem(key)); if (Array.isArray(v)) arr = v; } catch (e) {}
      const msg = { id: 'msg-staff-' + Date.now().toString(36), processId: proc.id, owner, applicant: pName(proc), sender: (user && user.name) || 'Ügyintéző', subject: msgDraft.subject || 'Üzenet a Külügyi Irodától', preview: msgDraft.body, attachments: msgDraft.attachments || [], date: todayStr(), read: false, tone: 'info' };
      try { localStorage.setItem(key, JSON.stringify([msg, ...arr])); } catch (e) {}
      spSaveMsg(msg);
      setThread(t => [...t, msg]);
      setMsgDraft({ subject: '', body: '', attachments: [] });
    };
    const runAiCheck = async (d, proc) => {
      setAiReport({ d, p: proc, loading: true });
      const entry = (proc.data && proc.data.docs && proc.data.docs[d.id]) || {};
      let docText = '';
      if ((entry.type || '').indexOf('pdf') >= 0) docText = await extractPdfText(await DOC_src(entry));
      const prompt = 'Egyetemi felvételi iroda dokumentum-ellenőrző asszisztense vagy. Elemezd a jelentkező feltöltött dokumentumát, és KIZÁRÓLAG érvényes, minifikált JSON-t adj vissza (markdown nélkül).\n\nElvárt dokumentumtípus (hely): "' + d.label + '"\nFájlnév: "' + (entry.fileName || '') + '"\nMIME típus: "' + (entry.type || 'ismeretlen') + '"\nFájlméret (bájt): ' + (entry.size || 0) + '\nJelentkező (űrlap szerint): ' + ((proc.data && proc.data.account && proc.data.account.fullName) || '') + '\n\nKinyert dokumentum-szöveg (üres lehet, ha kép/szkennelt):\n"""' + (docText || '(nincs kinyerhető szöveg)') + '"""\n\nA JSON pontosan ilyen szerkezetű legyen:\n{"detectedType":string,"matchesExpected":boolean,"authenticity":"authentic"|"review"|"suspicious","confidence":number,"extractedFields":{kulcs:ertek},"redFlags":[string],"summary":string,"recommendation":string}\nA szöveges mezők magyarul legyenek. Légy tömör és konkrét. Ha nincs kinyerhető szöveg, a metaadatok és a fájltípus alapján adj óvatos becslést, és jelezd a redFlags között.';
      try {
        if (!window.claude || !window.claude.complete) throw new Error('Az AI szolgáltatás nem elérhető ebben a nézetben.');
        const raw = await window.claude.complete({ messages: [{ role: 'user', content: prompt }] });
        let s = (raw || '').trim(); const a = s.indexOf('{'), b = s.lastIndexOf('}'); if (a >= 0 && b >= 0) s = s.slice(a, b + 1);
        const result = JSON.parse(s);
        setAiReport(r => (r && r.d && r.d.id === d.id) ? { ...r, loading: false, result } : r);
      } catch (e) {
        setAiReport(r => (r && r.d && r.d.id === d.id) ? { ...r, loading: false, error: 'Az AI elemzés nem sikerült. ' + ((e && e.message) || '') } : r);
      }
    };
    const avatarUrl = (pp) => { const ex = pp.data && pp.data.extracted; return ex ? ('https://i.pravatar.cc/96?u=' + encodeURIComponent((pp.data.account && pp.data.account.email) || pp.id || pp._owner || 'x')) : null; };
    const Face = ({ p, size = 44 }) => {
      const url = avatarUrl(p); const nm = pName(p);
      return (<div className="relative rounded-xl overflow-hidden bg-primary/10 text-primary flex items-center justify-center font-black flex-none" style={{ width: size, height: size }}><span>{(nm[0] || '?').toUpperCase()}</span>{url && <img src={url} alt="" className="absolute inset-0 w-full h-full object-cover" onError={e => { e.target.style.display = 'none'; }} />}</div>);
    };
    const downloadDoc = async (d, fileName, proc) => {
      const entry = (proc.data && proc.data.docs && proc.data.docs[d.id]) || {};
      const src = await DOC_src(entry);
      if (src) { const a = document.createElement('a'); a.href = src; a.download = fileName || 'dokumentum'; a.target = '_blank'; document.body.appendChild(a); a.click(); a.remove(); return; }
      const content = 'NEUMANN JÁNOS EGYETEM — Felvételi dokumentum (demó)\n\nJelentkező: ' + pName(proc) + '\nDokumentum: ' + d.label + '\nFájl: ' + fileName + '\n\n(Nincs csatolt fájl ehhez a tételhez.)';
      const blob = new Blob([content], { type: 'text/plain' });
      const url = URL.createObjectURL(blob); const a = document.createElement('a'); a.href = url; a.download = (fileName || 'dokumentum') + '.txt'; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
    };
    const toggleAttach = (d, fileName) => { const has = (msgDraft.attachments || []).some(a => a.id === d.id); const next = has ? (msgDraft.attachments || []).filter(a => a.id !== d.id) : [...(msgDraft.attachments || []), { id: d.id, label: d.label, fileName }]; setMsgDraft({ ...msgDraft, attachments: next }); };
    const toggleVerifyDoc = (proc, docId) => {
      const owner = proc._owner || 'demo';
      const key = 'nje_processes_' + owner;
      let arr = [];
      try { const v = JSON.parse(localStorage.getItem(key)); if (Array.isArray(v)) arr = v; } catch (e) {}
      const curDocs = (proc.data && proc.data.docs) || {};
      const entry = curDocs[docId];
      if (!entry || !entry.fileName) return;
      const newDocs = { ...curDocs, [docId]: { ...entry, verified: !entry.verified } };
      const reqIds = DT.filter(d => !d.optional).map(d => d.id);
      const allReqVerified = reqIds.every(id => newDocs[id] && newDocs[id].fileName && newDocs[id].verified);
      const wasVerified = !!(proc.data && proc.data.check && proc.data.check.verified);
      const newCheck = { ...((proc.data && proc.data.check) || {}), verified: allReqVerified, cleared: allReqVerified, duplicateChecked: true };
      if (allReqVerified && !wasVerified) newCheck.verifiedAt = todayStr();
      const newStep = proc.step || 0, newMax = proc.maxReached || 0;
      // Az admin csak hitelesít — a lépést a jelentkező lépteti tovább (a matek lépés nem ugorható át).
      const stored = { id: proc.id, createdAt: proc.createdAt, step: newStep, maxReached: newMax, done: proc.done || false, data: { ...(proc.data || {}), docs: newDocs, check: newCheck } };
      const idx = arr.findIndex(x => x.id === proc.id);
      if (idx >= 0) arr[idx] = stored; else arr = [stored, ...arr];
      try { localStorage.setItem(key, JSON.stringify(arr)); } catch (e) {}
      spSaveProc(owner, stored);
      const withOwner = { ...stored, _owner: owner };
      setJourneyProcs(ps => ps.map(x => x.id === proc.id ? withOwner : x));
      setDetailFull(withOwner);
    };

    if (detailFull) {
      const p = detailFull;
      const nm = pName(p);
      const docs = (p.data && p.data.docs) || {};
      const ex = (p.data && p.data.extracted) || {};
      const iv = (p.data && p.data.interview) || {};
      const letter = (p.data && p.data.letter) || {};
      const progs = ((p.data && p.data.programs) || []).map(id => PROGS.find(x => x.id === id)).filter(Boolean);
      const reqDocs = DT.filter(d => !d.optional);
      const missingReq = reqDocs.filter(d => !(docs[d.id] && docs[d.id].fileName));
      const verified = !!(p.data && p.data.check && p.data.check.verified);
      const verifiedReq = reqDocs.filter(d => docs[d.id] && docs[d.id].fileName && docs[d.id].verified).length;
      return (
        <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
          <button onClick={() => { setDetailFull(null); setMsgSent(false); }} className="text-sm text-slate-400 hover:text-slate-600 inline-flex items-center gap-1.5"><Lucide.ChevronLeft size={15} /> Vissza a jelentkezésekhez</button>
          <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6 flex items-center gap-4">
            <Face p={p} size={64} />
            <div className="flex-1 min-w-0">
              <h3 className="text-xl font-black text-slate-800">{nm}</h3>
              <p className="text-sm text-slate-400">{(p.data && p.data.account && p.data.account.email) || p._owner || ''}</p>
              <div className="flex flex-wrap gap-1 mt-2">{progs.map(pr => <span key={pr.id} className="px-2 py-0.5 bg-primary/10 text-primary rounded text-[10px] font-bold">{pr.code} {pr.name}</span>)}</div>
            </div>
            <span className={'text-xs font-bold px-3 py-1.5 rounded-full ' + (p.done ? 'bg-emerald-50 text-emerald-600' : 'bg-primary/10 text-primary')}>{p.done ? 'Felvéve' : ((SD[p.step] || {}).label || '—')}</span>
          </div>
          <div className="grid lg:grid-cols-3 gap-6">
            <div className="lg:col-span-2 space-y-6">
              <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6">
                <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Folyamat állapota</div>
                <div className="flex flex-wrap gap-2">{SD.map((s, i) => { const dn = p.done || i < p.step; const ac = !p.done && i === p.step; return <span key={s.id} className={'text-[11px] font-bold px-2.5 py-1 rounded-full inline-flex items-center gap-1 ' + (dn ? 'bg-emerald-50 text-emerald-600' : ac ? 'bg-primary text-white' : 'bg-slate-100 text-slate-400')}>{dn && <Lucide.Check size={11} />}{i + 1}. {s.label}</span>; })}</div>
              </div>
              <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6">
                <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-4">Dokumentumok</div>
                <div className="space-y-2">
                  {DT.map(d => { const up = docs[d.id] && docs[d.id].fileName; const dv = up && docs[d.id].verified; const attached = (msgDraft.attachments || []).some(a => a.id === d.id); return (
                    <div key={d.id} className="rounded-xl border border-slate-100 overflow-hidden"><div className="flex items-center gap-3 p-3 flex-wrap">
                      <span className={'w-9 h-9 rounded-lg flex items-center justify-center flex-none ' + (dv ? 'bg-emerald-50 text-emerald-600' : up ? 'bg-primary/10 text-primary' : 'bg-slate-100 text-slate-300')}>{dv ? <Lucide.ShieldCheck size={18} /> : <d.Icon size={18} />}</span>
                      <div className="flex-1 min-w-0"><div className="text-sm font-bold text-slate-700 flex items-center gap-1.5">{d.label}{d.optional && <span className="text-[10px] text-slate-400 font-normal">(opcionális)</span>}{dv && <span className="text-[10px] font-bold text-emerald-600 inline-flex items-center gap-0.5"><Lucide.Check size={10} /> hitelesítve</span>}</div><div className="text-xs text-slate-400 truncate">{up ? docs[d.id].fileName : 'Nincs feltöltve'}</div></div>
                      {up ? (<div className="flex items-center gap-1.5 flex-wrap">
                        <button onClick={() => toggleVerifyDoc(p, d.id)} className={'px-2.5 py-1.5 rounded-lg text-[11px] font-bold inline-flex items-center gap-1 ' + (dv ? 'bg-emerald-100 text-emerald-700 hover:bg-emerald-200' : 'bg-emerald-600 text-white hover:bg-emerald-700')}>{dv ? <><Lucide.X size={13} /> Visszavonás</> : <><Lucide.ShieldCheck size={13} /> Jóváhagyás</>}</button>
                        <button onClick={() => setPreviewDoc({ d, fileName: docs[d.id].fileName, p })} className="px-2.5 py-1.5 rounded-lg text-[11px] font-bold bg-slate-100 text-slate-600 hover:bg-slate-200 inline-flex items-center gap-1"><Lucide.Eye size={13} /> Előnézet</button>
                        <button onClick={() => runAiCheck(d, p)} className="px-2.5 py-1.5 rounded-lg text-[11px] font-bold bg-primary/10 text-primary hover:bg-primary/20 inline-flex items-center gap-1"><Lucide.ScanSearch size={13} /> AI Check</button>
                        <button onClick={() => downloadDoc(d, docs[d.id].fileName, p)} className="px-2.5 py-1.5 rounded-lg text-[11px] font-bold bg-slate-100 text-slate-600 hover:bg-slate-200 inline-flex items-center gap-1"><Lucide.Download size={13} /> Letöltés</button>
                        <button onClick={() => toggleAttach(d, docs[d.id].fileName)} className={'px-2.5 py-1.5 rounded-lg text-[11px] font-bold inline-flex items-center gap-1 ' + (attached ? 'bg-primary text-white' : 'bg-slate-100 text-slate-600 hover:bg-slate-200')}><Lucide.Paperclip size={13} /> {attached ? 'Hivatkozva' : 'Hivatkozás'}</button>
                      </div>) : <span className="text-[10px] font-bold text-red-500">hiányzik</span>}
                    </div>
                    {up && p.data && p.data.aiChecks && p.data.aiChecks[d.id] && (() => { const c = p.data.aiChecks[d.id]; const ok = c.verdict === 'authentic'; return (
                      <div className={'border-t px-3 py-2.5 ' + (ok ? 'bg-emerald-50/60 border-emerald-100' : 'bg-amber-50/60 border-amber-100')}>
                        <div className="flex items-center justify-between gap-2 flex-wrap">
                          <div className="flex items-center gap-1.5 text-[11px] font-bold text-slate-600"><Lucide.ScanSearch size={12} className="text-primary" /> Felismert típus: <span className="text-slate-800">{c.detected}</span></div>
                          <span className={'text-[10px] font-bold px-2 py-0.5 rounded-full inline-flex items-center gap-1 ' + (ok ? 'bg-emerald-100 text-emerald-700' : 'bg-amber-100 text-amber-700')}>{ok ? <><Lucide.ShieldCheck size={11} /> Valódinak tűnik</> : <><Lucide.AlertTriangle size={11} /> Ellenőrzés javasolt</>} · {c.score}%</span>
                        </div>
                        {c.flags && c.flags.length > 0 && <div className="mt-1.5 flex flex-wrap gap-1">{c.flags.map((f, i) => <span key={i} className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-red-50 text-red-600 inline-flex items-center gap-1"><Lucide.Flag size={9} /> {f}</span>)}</div>}
                      </div>
                    ); })()}
                    {up && p.data && p.data.aiExtracts && p.data.aiExtracts[d.id] && (
                      <div className="bg-slate-50 border-t border-slate-100 px-3 py-2.5">
                        <div className="text-[10px] font-bold uppercase tracking-wide text-primary mb-1.5 flex items-center gap-1"><Lucide.Sparkles size={11} /> AI kivonat</div>
                        <div className="grid grid-cols-2 gap-x-4 gap-y-1">
                          {Object.entries(p.data.aiExtracts[d.id]).map(([k, v]) => (<div key={k} className="flex justify-between gap-2 text-[11px]"><span className="text-slate-400">{k}</span><span className="font-bold text-slate-700 text-right truncate">{String(v)}</span></div>))}
                        </div>
                      </div>
                    )}
                    </div>
                  ); })}
                </div>
              </div>
              {(ex.name || ex.passportNumber) && (
                <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6"><div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Kinyert adatok (útlevél)</div><div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm"><div><span className="text-slate-400 text-xs">Név</span><div className="font-bold text-slate-700">{ex.name || '—'}</div></div><div><span className="text-slate-400 text-xs">Útlevélszám</span><div className="font-bold text-slate-700">{ex.passportNumber || '—'}</div></div><div><span className="text-slate-400 text-xs">Ország</span><div className="font-bold text-slate-700">{ex.country || '—'}</div></div><div><span className="text-slate-400 text-xs">Szül. dátum</span><div className="font-bold text-slate-700">{ex.birthDate || '—'}</div></div></div></div>
              )}
            </div>
            <div className="space-y-6">
              <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6">
                <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Dokumentum hitelesítés</div>
                {verified ? (
                  <div className="rounded-xl bg-emerald-50 border border-emerald-200 p-4">
                    <div className="flex items-center gap-2 text-emerald-700 font-bold text-sm"><Lucide.ShieldCheck size={18} /> Minden dokumentum hitelesítve</div>
                    <div className="text-xs text-emerald-600 mt-1">Jóváhagyva: {(p.data.check && p.data.check.verifiedAt) || '—'}. A folyamat továbblépett.</div>
                  </div>
                ) : (
                  <div>
                    <div className="flex items-center justify-between mb-2"><span className="text-sm font-bold text-slate-700">{verifiedReq} / {reqDocs.length} kötelező hitelesítve</span>{missingReq.length > 0 && <span className="text-[11px] font-bold text-amber-600">{missingReq.length} hiányzik</span>}</div>
                    <div className="h-1.5 bg-slate-100 rounded-full overflow-hidden mb-3"><div className="h-full bg-emerald-500 rounded-full transition-all" style={{ width: (reqDocs.length ? Math.round(verifiedReq / reqDocs.length * 100) : 0) + '%' }}></div></div>
                    <p className="text-xs text-slate-500">Hitelesítsd a dokumentumokat egyesével a bal oldali listában a „Jóváhagyás” gombbal. Ha minden kötelező dokumentum hitelesítve, a folyamat automatikusan továbblép.</p>
                  </div>
                )}
              </div>
              {(() => {
                const matches = journeyProcs.filter(o => o.id !== p.id).map(o => {
                  const oex = (o.data && o.data.extracted) || {}; const oacc = (o.data && o.data.account) || {};
                  const oname = oex.name || oacc.fullName || '';
                  const reasons = [];
                  if (ex.passportNumber && oex.passportNumber && oex.passportNumber === ex.passportNumber) reasons.push('Azonos útlevélszám');
                  if ((ex.name || '') && oname && oname.toLowerCase() === (ex.name || '').toLowerCase()) reasons.push('Azonos név');
                  const myEmail = (p.data && p.data.account && p.data.account.email) || '';
                  if (myEmail && oacc.email && oacc.email.toLowerCase() === myEmail.toLowerCase()) reasons.push('Azonos e-mail');
                  return reasons.length ? { name: oname || 'Jelentkező', passport: oex.passportNumber || '—', reason: reasons.join(', ') } : null;
                }).filter(Boolean);
                return (
                  <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6">
                    <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3 flex items-center gap-2"><Lucide.Fingerprint size={14} className="text-primary" /> Duplicate Finder</div>
                    {matches.length ? (
                      <div className="space-y-2">
                        <div className="flex items-center gap-2 text-red-600 font-bold text-sm"><Lucide.AlertTriangle size={16} /> {matches.length} lehetséges egyezés</div>
                        {matches.map((m, i) => (<div key={i} className="rounded-xl border border-red-200 bg-red-50 p-3"><div className="font-bold text-red-800 text-sm">{m.name}</div><div className="text-xs text-red-600 mt-0.5">Útlevél: {m.passport}</div><div className="text-xs text-red-700 font-bold mt-1">⚠ {m.reason}</div></div>))}
                      </div>
                    ) : (
                      <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-3 flex items-center gap-3"><Lucide.ShieldCheck size={20} className="text-emerald-600" /><div><div className="font-bold text-emerald-800 text-sm">Nincs egyezés</div><div className="text-xs text-emerald-600">A jelentkezés egyedinek tűnik.</div></div></div>
                    )}
                  </div>
                );
              })()}
              <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6">
                <div className="flex items-center justify-between mb-3"><div className="text-xs font-bold text-slate-400 uppercase tracking-wide">Beszélgetés a jelentkezővel</div><span className="text-[10px] font-bold text-slate-400">{thread.length} üzenet</span></div>
                <div className="space-y-3 max-h-[420px] overflow-y-auto pr-1 mb-4">
                  {thread.length === 0 ? <div className="text-center py-10 text-slate-400 text-sm">Még nincs üzenet ezzel a jelentkezővel.</div> : thread.map(m => {
                    const officer = m.sender && m.sender !== pName(p) && m.sender !== (m.applicant || '');
                    return (
                      <div key={m.id} className={'flex ' + (officer ? 'justify-end' : 'justify-start')}>
                        <div className={'max-w-[88%] rounded-2xl px-4 py-2.5 ' + (officer ? 'bg-primary text-white' : 'bg-slate-100 text-slate-800')}>
                          <div className={'text-[10px] font-bold mb-0.5 ' + (officer ? 'text-white/70' : 'text-slate-500')}>{officer ? (m.sender + ' · Külügyi Iroda') : (m.applicant || 'Jelentkező')}{m.date ? ' · ' + m.date : ''}</div>
                          {m.subject && <div className="text-sm font-bold">{m.subject}</div>}
                          <div className="text-sm whitespace-pre-wrap">{m.preview}</div>
                          {m.attachments && m.attachments.length > 0 && <div className="flex flex-wrap gap-1 mt-1.5">{m.attachments.map(a => <span key={a.id} className={'text-[10px] font-bold px-2 py-0.5 rounded-full inline-flex items-center gap-1 ' + (officer ? 'bg-white/20' : 'bg-white')}><Lucide.Paperclip size={9} /> {a.label}</span>)}</div>}
                        </div>
                      </div>
                    );
                  })}
                </div>
                <div className="space-y-2 border-t border-slate-100 pt-3">
                  <input value={msgDraft.subject} onChange={e => setMsgDraft({ ...msgDraft, subject: e.target.value })} placeholder="Tárgy (opcionális)" className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none" />
                  <textarea value={msgDraft.body} onChange={e => setMsgDraft({ ...msgDraft, body: e.target.value })} rows={2} placeholder="Írj üzenetet a jelentkezőnek…" className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none resize-none"></textarea>
                  {(msgDraft.attachments || []).length > 0 && (<div className="flex flex-wrap gap-1.5">{msgDraft.attachments.map(a => <span key={a.id} className="text-[10px] font-bold px-2 py-1 rounded-full bg-primary/10 text-primary inline-flex items-center gap-1"><Lucide.Paperclip size={10} /> {a.label}<button onClick={() => toggleAttach({ id: a.id, label: a.label }, a.fileName)} className="ml-0.5 hover:text-primary/70"><Lucide.X size={10} /></button></span>)}</div>)}
                  <button onClick={() => sendMessage(p)} disabled={!msgDraft.body.trim()} className="w-full bg-primary text-white px-5 py-2.5 rounded-xl font-bold text-sm hover:bg-primary/90 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center justify-center gap-2"><Lucide.Send size={15} /> Küldés</button>
                </div>
              </div>
              {(iv.booked || letter.fileNumber) && (
                <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-6 space-y-3">
                  {iv.booked && <div><div className="text-xs font-bold text-slate-500 mb-1 flex items-center gap-1"><Lucide.Video size={13} /> Interjú</div><div className="text-sm font-bold text-slate-700">{iv.slot && iv.slot.day} · {iv.slot && iv.slot.time}</div><div className="text-xs text-slate-400">{iv.slot && iv.slot.who}</div></div>}
                  {letter.fileNumber && <div><div className="text-xs font-bold text-emerald-700 mb-1 flex items-center gap-1"><Lucide.FileCheck size={13} /> Felvételi levél</div><div className="text-sm font-bold text-emerald-800 font-mono">{letter.fileNumber}</div></div>}
                </div>
              )}
            </div>
          </div>
          {previewDoc && (
            <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/50 backdrop-blur-sm" onClick={() => setPreviewDoc(null)}>
              <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg overflow-hidden" onClick={e => e.stopPropagation()}>
                <div className="p-4 border-b border-slate-100 flex items-center justify-between"><div className="font-bold text-slate-800 text-sm flex items-center gap-2"><previewDoc.d.Icon size={16} className="text-primary" /> {previewDoc.d.label}</div><button onClick={() => setPreviewDoc(null)} className="text-slate-400 hover:text-slate-700"><Lucide.X size={18} /></button></div>
                <div className="p-4 bg-slate-50">
                  {(() => { const e = (previewDoc.p.data && previewDoc.p.data.docs && previewDoc.p.data.docs[previewDoc.d.id]) || {}; return (e.path || e.dataUrl) ? <DocViewer entry={e} fileName={previewDoc.fileName} /> : (
                    <div className="bg-white border border-slate-200 rounded-xl mx-auto max-h-[55vh] aspect-[3/4] w-full max-w-xs flex flex-col items-center justify-center text-center p-6"><previewDoc.d.Icon size={48} className="text-slate-300 mb-4" /><div className="font-mono text-xs text-slate-400">{previewDoc.fileName}</div><div className="font-bold text-slate-700 mt-2">{previewDoc.d.label}</div>{previewDoc.d.id === 'passport' && previewDoc.p.data && previewDoc.p.data.extracted && (<div className="mt-4 text-xs text-slate-500 space-y-0.5"><div>{previewDoc.p.data.extracted.name}</div><div>{previewDoc.p.data.extracted.passportNumber}</div><div>{previewDoc.p.data.extracted.country}</div></div>)}<div className="mt-4 text-[10px] text-slate-300">Nincs csatolt fájl</div></div>
                  ); })()}
                </div>
                <div className="p-4 border-t border-slate-100 flex justify-end"><button onClick={() => downloadDoc(previewDoc.d, previewDoc.fileName, previewDoc.p)} className="bg-primary text-white px-4 py-2 rounded-lg text-sm font-bold inline-flex items-center gap-1.5"><Lucide.Download size={14} /> Letöltés</button></div>
              </div>
            </div>
          )}
          {aiReport && (() => {
            const d = aiReport.d, ap = aiReport.p; const R = aiReport.result || {};
            const auth = R.authenticity || 'review'; const ok = auth === 'authentic'; const sus = auth === 'suspicious';
            const score = typeof R.confidence === 'number' ? R.confidence : null;
            const fields = R.extractedFields || {};
            return (
              <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/50 backdrop-blur-sm" onClick={() => setAiReport(null)}>
                <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg max-h-[88vh] overflow-y-auto" onClick={e => e.stopPropagation()}>
                  <div className="p-5 border-b border-slate-100 flex items-start justify-between">
                    <div className="flex items-center gap-2.5"><span className="w-9 h-9 rounded-xl bg-primary/10 text-primary flex items-center justify-center"><Lucide.ScanSearch size={18} /></span><div><div className="font-black text-slate-800">AI dokumentum-riport</div><div className="text-xs text-slate-400">{pName(ap)} · {d.label}</div></div></div>
                    <button onClick={() => setAiReport(null)} className="text-slate-400 hover:text-slate-700"><Lucide.X size={20} /></button>
                  </div>
                  {aiReport.loading ? (
                    <div className="p-10 text-center"><Lucide.Loader2 size={28} className="text-primary animate-spin mx-auto mb-3" /><div className="font-bold text-slate-700">AI elemzés folyamatban…</div><div className="text-xs text-slate-400 mt-1">A dokumentum beolvasása és valódiság-ellenőrzése.</div></div>
                  ) : aiReport.error ? (
                    <div className="p-8 text-center"><Lucide.AlertTriangle size={28} className="text-red-500 mx-auto mb-3" /><div className="font-bold text-red-600">{aiReport.error}</div><button onClick={() => runAiCheck(d, ap)} className="mt-4 bg-slate-900 text-white px-4 py-2 rounded-lg text-sm font-bold inline-flex items-center gap-1.5"><Lucide.RefreshCw size={14} /> Újrafuttatás</button></div>
                  ) : (
                    <div className="p-5 space-y-4">
                      <div className={'rounded-xl p-4 ' + (ok ? 'bg-emerald-50 border border-emerald-200' : sus ? 'bg-red-50 border border-red-200' : 'bg-amber-50 border border-amber-200')}>
                        <div className="flex items-center justify-between"><div className={'font-black inline-flex items-center gap-2 ' + (ok ? 'text-emerald-700' : sus ? 'text-red-700' : 'text-amber-700')}>{ok ? <Lucide.ShieldCheck size={18} /> : <Lucide.AlertTriangle size={18} />} {ok ? 'Valódinak tűnik' : sus ? 'Gyanús — elutasítás megfontolandó' : 'Ellenőrzés javasolt'}</div>{score != null && <div className="text-2xl font-black text-slate-800">{score}<span className="text-sm text-slate-400">%</span></div>}</div>
                        {score != null && <div className="mt-2 h-2 bg-white/60 rounded-full overflow-hidden"><div className={(ok ? 'bg-emerald-500' : sus ? 'bg-red-500' : 'bg-amber-500') + ' h-full rounded-full'} style={{ width: score + '%' }}></div></div>}
                      </div>
                      {R.summary && <div className="text-[13px] text-slate-600 leading-relaxed">{R.summary}</div>}
                      <div className="grid grid-cols-2 gap-3 text-sm">
                        <div><div className="text-xs text-slate-400">Felismert típus</div><div className="font-bold text-slate-700">{R.detectedType || '—'}</div></div>
                        <div><div className="text-xs text-slate-400">Elvárt típus</div><div className="font-bold text-slate-700">{d.label}</div></div>
                        <div><div className="text-xs text-slate-400">Típus-egyezés</div><div className={'font-bold ' + (R.matchesExpected ? 'text-emerald-600' : 'text-red-600')}>{R.matchesExpected ? 'Egyezik' : 'Eltérés'}</div></div>
                        <div><div className="text-xs text-slate-400">Forrás</div><div className="font-bold text-slate-700">{(ap.data && ap.data.docs && ap.data.docs[d.id] && (ap.data.docs[d.id].type || '').indexOf('pdf') >= 0) ? 'PDF szövegelemzés' : 'Metaadat-becslés'}</div></div>
                      </div>
                      {Object.keys(fields).length > 0 && <div><div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-2">Kinyert adatok</div><div className="rounded-xl border border-slate-100 divide-y divide-slate-50">{Object.entries(fields).map(([k, v]) => <div key={k} className="flex justify-between gap-3 px-3 py-1.5 text-[13px]"><span className="text-slate-400">{k}</span><span className="font-bold text-slate-700 text-right">{typeof v === 'object' ? JSON.stringify(v) : String(v)}</span></div>)}</div></div>}
                      <div><div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-2">Észlelt jelzők</div>{(R.redFlags && R.redFlags.length) ? <div className="space-y-1.5">{R.redFlags.map((f, i) => <div key={i} className="text-[13px] text-red-600 inline-flex items-start gap-1.5"><Lucide.Flag size={12} className="mt-0.5 shrink-0" /> {f}</div>)}</div> : <div className="text-[13px] text-emerald-600 inline-flex items-center gap-1.5"><Lucide.CheckCircle2 size={13} /> Nincs gyanús jelző.</div>}</div>
                      {R.recommendation && <div className="rounded-xl bg-slate-50 p-3 text-[13px] text-slate-600"><span className="font-bold text-slate-700">Javaslat: </span>{R.recommendation}</div>}
                    </div>
                  )}
                  <div className="p-4 border-t border-slate-100 flex justify-end gap-2">
                    {!aiReport.loading && <button onClick={() => runAiCheck(d, ap)} className="px-4 py-2 rounded-lg text-sm font-bold bg-slate-100 text-slate-600 hover:bg-slate-200 inline-flex items-center gap-1.5"><Lucide.RefreshCw size={14} /> Újrafuttatás</button>}
                    <button onClick={() => setAiReport(null)} className="bg-primary text-white px-4 py-2 rounded-lg text-sm font-bold">Bezárás</button>
                  </div>
                </div>
              </div>
            );
          })()}
        </div>
      );
    }

    return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Élő felvételi folyamat státusz */}
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50 flex justify-between items-center">
          <div>
            <h3 className="font-bold text-slate-800 text-lg">Felvételi folyamat — élő állapot</h3>
            <p className="text-xs text-slate-400 mt-0.5">Hol tart minden jelentkező és milyen dokumentum hiányzik még</p>
          </div>
          <div className="flex items-center gap-3">
            <RefreshingBadge on={procsRefreshing} />
            {procsLoading
              ? <SkeletonBar w={82} h={26} className="rounded-full" />
              : <span className="px-3 py-1 bg-primary/10 text-primary rounded-full text-xs font-bold">{journeyProcs.length} folyamat</span>}
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Jelentkező</th>
                <th className="px-6 py-4">Szakok</th>
                <th className="px-6 py-4">Folyamat</th>
                <th className="px-6 py-4">Hiányzó dokumentumok</th>
                <th className="px-6 py-4">Állapot</th>
                <th className="px-6 py-4 text-right">Művelet</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {procsLoading && <SkeletonRows rows={6} cols={['62%', '38%', '70%', '80%', '52%', '34%']} />}
              {!procsLoading && journeyProcs.map((p, idx) => {
                const nm = pName(p);
                const progs = ((p.data && p.data.programs) || []).map(id => { const pr = PROGS.find(x => x.id === id); return pr ? pr.code : null; }).filter(Boolean);
                const docs = (p.data && p.data.docs) || {};
                const missing = reqDocs.filter(d => !(docs[d.id] && docs[d.id].fileName));
                const pct = p.done ? 100 : Math.round(((p.maxReached || 0) / Math.max(SD.length - 1, 1)) * 100);
                const stLabel = p.done ? 'Felvéve' : (SD[p.step] ? SD[p.step].label : '—');
                const cancelled = !!(p.data && p.data._cancelled);
                return (
                  <tr key={p.id || idx} className={'hover:bg-slate-50 transition-colors align-top' + (cancelled ? ' opacity-70' : '')}>
                    <td className="px-6 py-4"><div className="flex items-center gap-3"><Face p={p} size={36} /><div className="min-w-0"><p className="font-semibold text-slate-800 truncate">{nm}</p><p className="text-xs text-slate-400 truncate">{(p.data && p.data.account && p.data.account.email) || p._owner || ''}</p></div></div></td>
                    <td className="px-6 py-4"><div className="flex flex-wrap gap-1">{progs.length ? progs.map(c => <span key={c} className="px-2 py-0.5 bg-primary/10 text-primary rounded text-[10px] font-bold">{c}</span>) : <span className="text-[10px] text-slate-400">—</span>}</div></td>
                    <td className="px-6 py-4"><div className="w-32"><div className="flex items-center justify-between text-[10px] font-bold mb-1"><span className={cancelled ? 'text-red-500' : p.done ? 'text-emerald-600' : 'text-primary'}>{cancelled ? 'Megszakítva' : stLabel}</span><span className="text-slate-400">{(p.done ? SD.length : (p.maxReached || 0) + 1)}/{SD.length}</span></div><div className="h-1.5 bg-slate-100 rounded-full overflow-hidden"><div className={(cancelled ? 'bg-red-300' : p.done ? 'bg-emerald-500' : 'bg-primary') + ' h-full rounded-full'} style={{ width: pct + '%' }}></div></div></div></td>
                    <td className="px-6 py-4">{missing.length ? <div className="flex flex-wrap gap-1 max-w-xs">{missing.map(d => <span key={d.id} className="px-2 py-0.5 bg-red-50 text-red-600 rounded text-[10px] font-bold inline-flex items-center gap-1"><ICONS.AlertCircle size={11} /> {d.label}</span>)}</div> : <span className="text-[10px] font-bold text-emerald-600 inline-flex items-center gap-1"><ICONS.CheckCircle size={12} /> Minden feltöltve</span>}</td>
                    <td className="px-6 py-4"><span className={`text-[10px] font-bold px-2 py-1 rounded-full whitespace-nowrap inline-flex items-center gap-1 ${cancelled ? 'bg-red-50 text-red-600' : p.done ? 'bg-emerald-50 text-emerald-600' : 'bg-primary/10 text-primary'}`}>{cancelled ? <><ICONS.XCircle size={11} /> Megszakítva</> : p.done ? 'Felvéve · levél kiállítva' : stLabel}</span></td>
                    <td className="px-6 py-4 text-right"><button onClick={() => { setDetailProc(p); setMsgDraft({ subject: '', body: '' }); setMsgSent(false); }} className="bg-slate-900 text-white px-3 py-1.5 rounded-lg text-[11px] font-bold hover:bg-slate-800 inline-flex items-center gap-1.5"><ICONS.Eye size={13} /> Részletek</button></td>
                  </tr>
                );
              })}
              {journeyProcs.length === 0 && <tr><td colSpan={6} className="px-6 py-8 text-center text-slate-400 text-sm">Nincs aktív felvételi folyamat.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {detailProc && (() => {
        const p = detailProc;
        const nm = pName(p);
        const docs = (p.data && p.data.docs) || {};
        const ex = (p.data && p.data.extracted) || {};
        const iv = (p.data && p.data.interview) || {};
        const letter = (p.data && p.data.letter) || {};
        return (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/40 backdrop-blur-sm" onClick={() => setDetailProc(null)}>
            <div className="bg-white rounded-3xl shadow-2xl w-full max-w-2xl max-h-[90vh] overflow-y-auto" onClick={e => e.stopPropagation()}>
              <div className="p-6 border-b border-slate-100 flex items-start justify-between sticky top-0 bg-white z-10">
                <div className="flex items-center gap-3">
                  <Face p={p} size={48} />
                  <div><h3 className="text-lg font-black text-slate-800">{nm}</h3><p className="text-xs text-slate-400">{(p.data && p.data.account && p.data.account.email) || p._owner || ''}</p></div>
                </div>
                <div className="flex items-center gap-2">
                  <button onClick={() => { setDetailFull(p); setDetailProc(null); setMsgSent(false); spFetchProc(p.id).then(full => { if (full) setDetailFull(cur => (cur && cur.id === p.id) ? { ...cur, ...full } : cur); }); }} className="bg-primary text-white px-3 py-1.5 rounded-lg text-[11px] font-bold hover:bg-primary/90 inline-flex items-center gap-1.5"><Lucide.Maximize2 size={13} /> Részletes nézet</button>
                  <button onClick={() => setDetailProc(null)} className="text-slate-400 hover:text-slate-700"><Lucide.X size={22} /></button>
                </div>
              </div>
              <div className="p-6 space-y-6">
                <div>
                  <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Folyamat állapota</div>
                  <div className="flex flex-wrap gap-2">
                    {SD.map((s, i) => { const dn = p.done || i < p.step; const ac = !p.done && i === p.step; return <span key={s.id} className={`text-[11px] font-bold px-2.5 py-1 rounded-full inline-flex items-center gap-1 ${dn ? 'bg-emerald-50 text-emerald-600' : ac ? 'bg-primary text-white' : 'bg-slate-100 text-slate-400'}`}>{dn && <Lucide.Check size={11} />}{i + 1}. {s.label}</span>; })}
                  </div>
                </div>
                <div>
                  <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Feltöltött dokumentumok</div>
                  <div className="space-y-2">
                    {DT.map(d => { const up = docs[d.id] && docs[d.id].fileName; return (
                      <div key={d.id} className="flex items-center gap-3 p-2.5 rounded-xl border border-slate-100">
                        <span className={`w-8 h-8 rounded-lg flex items-center justify-center ${up ? 'bg-emerald-50 text-emerald-600' : 'bg-red-50 text-red-500'}`}>{up ? <Lucide.Check size={16} /> : <Lucide.X size={16} />}</span>
                        <div className="flex-1 min-w-0"><div className="text-sm font-bold text-slate-700">{d.label}{d.optional && <span className="ml-1 text-[10px] text-slate-400 font-normal">(opcionális)</span>}</div><div className="text-xs text-slate-400 truncate">{up ? docs[d.id].fileName : 'Nincs feltöltve'}</div></div>
                      </div>
                    ); })}
                  </div>
                </div>
                {(ex.name || ex.passportNumber) && (
                  <div>
                    <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Kinyert adatok (útlevél)</div>
                    <div className="grid grid-cols-2 gap-3 text-sm">
                      <div><span className="text-slate-400 text-xs">Név</span><div className="font-bold text-slate-700">{ex.name || '—'}</div></div>
                      <div><span className="text-slate-400 text-xs">Útlevélszám</span><div className="font-bold text-slate-700">{ex.passportNumber || '—'}</div></div>
                      <div><span className="text-slate-400 text-xs">Ország</span><div className="font-bold text-slate-700">{ex.country || '—'}</div></div>
                      <div><span className="text-slate-400 text-xs">Szül. dátum</span><div className="font-bold text-slate-700">{ex.birthDate || '—'}</div></div>
                    </div>
                  </div>
                )}
                {(iv.booked || letter.fileNumber) && (
                  <div className="grid sm:grid-cols-2 gap-3">
                    {iv.booked && <div className="rounded-xl bg-slate-50 p-3"><div className="text-xs font-bold text-slate-500 mb-1 flex items-center gap-1"><Lucide.Video size={13} /> Interjú</div><div className="text-sm font-bold text-slate-700">{iv.slot && iv.slot.day} · {iv.slot && iv.slot.time}</div><div className="text-xs text-slate-400">{iv.slot && iv.slot.who}</div></div>}
                    {letter.fileNumber && <div className="rounded-xl bg-emerald-50 p-3"><div className="text-xs font-bold text-emerald-700 mb-1 flex items-center gap-1"><Lucide.FileCheck size={13} /> Felvételi levél</div><div className="text-sm font-bold text-emerald-800 font-mono">{letter.fileNumber}</div></div>}
                  </div>
                )}
                <div className="border-t border-slate-100 pt-5">
                  <div className="text-xs font-bold text-slate-400 uppercase tracking-wide mb-3">Üzenet írása a jelentkezőnek</div>
                  {msgSent ? (
                    <div className="rounded-xl bg-emerald-50 border border-emerald-200 p-4 flex items-center gap-3"><Lucide.CheckCircle2 size={20} className="text-emerald-600" /><div><div className="font-bold text-emerald-800 text-sm">Üzenet elküldve</div><div className="text-xs text-emerald-600">A jelentkező az Üzenetek között látja.</div></div></div>
                  ) : (
                    <div className="space-y-3">
                      <input value={msgDraft.subject} onChange={e => setMsgDraft({ ...msgDraft, subject: e.target.value })} placeholder="Tárgy" className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none" />
                      <textarea value={msgDraft.body} onChange={e => setMsgDraft({ ...msgDraft, body: e.target.value })} rows={3} placeholder="Írd meg az üzenetet…" className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none resize-none"></textarea>
                      <div className="flex justify-end"><button onClick={() => sendMessage(p)} disabled={!msgDraft.body.trim()} className="bg-primary text-white px-5 py-2.5 rounded-xl font-bold text-sm hover:bg-primary/90 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center gap-2"><Lucide.Send size={15} /> Üzenet küldése</button></div>
                    </div>
                  )}
                </div>
              </div>
            </div>
          </div>
        );
      })()}

      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50 flex justify-between items-center">
          <h3 className="font-bold text-slate-800 text-lg">Aktív Jelentkezések (Multi-Program)</h3>
          <div className="flex gap-2">
            <span className="px-3 py-1 bg-amber-50 text-amber-600 rounded-full text-xs font-bold flex items-center gap-1">
              <ICONS.AlertCircle size={14} /> {isLoading ? '…' : students.filter(s => s.status === 'Missing Info').length} Hiánypótlás szükséges
            </span>
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Diák</th>
                <th className="px-6 py-4">Választott Szakok</th>
                <th className="px-6 py-4">Dokumentumok</th>
                <th className="px-6 py-4">Ajánlások</th>
                <th className="px-6 py-4">AI Státusz</th>
                <th className="px-6 py-4 text-right">Műveletek</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {isLoading && <SkeletonRows rows={5} cols={['58%', '46%', '64%', '40%', '56%', '30%']} />}
              {!isLoading && students.map(student => (
                <tr key={student.id} className="hover:bg-slate-50 transition-colors">
                  <td className="px-6 py-4">
                    <p className="font-semibold text-slate-800">{student.name}</p>
                    <p className="text-xs text-slate-400">{student.email}</p>
                  </td>
                  <td className="px-6 py-4">
                    <div className="flex flex-wrap gap-1">
                      <span className="px-2 py-0.5 bg-indigo-50 text-indigo-600 rounded text-[10px] font-bold">{student.program}</span>
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    <div className="flex items-center gap-2">
                      <div className="w-24 bg-slate-100 h-1.5 rounded-full overflow-hidden">
                        <div className={`h-full ${student.status === 'Missing Info' ? 'bg-amber-500 w-1/4' : 'bg-emerald-500 w-full'}`}></div>
                      </div>
                      <span className="text-[10px] font-bold text-slate-500">{student.status === 'Missing Info' ? '1/4' : '4/4'}</span>
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    <div className="flex items-center gap-1">
                      <span className={`text-[10px] font-bold ${
                        (student.recommendationLetters?.filter(l => l.status === 'Verified').length || 0) >= 1 ? 'text-emerald-500' : 'text-slate-400'
                      }`}>
                        {student.recommendationLetters?.filter(l => l.status === 'Verified').length || 0} beérkezett
                      </span>
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    <span className={`${student.status === 'Paid' || student.status === 'Accepted' ? 'text-emerald-500' : 'text-slate-400'} flex items-center gap-1 text-xs font-semibold`}>
                      {student.status === 'Paid' || student.status === 'Accepted' ? <ICONS.CheckCircle size={14} /> : <ICONS.Clock size={14} />}
                      {student.status === 'Paid' || student.status === 'Accepted' ? 'Ellenőrizve' : 'Várat magára'}
                    </span>
                  </td>
                  <td className="px-6 py-4 text-right">
                    <div className="flex justify-end gap-2">
                      {student.status === 'Submitted' && (
                        <button 
                          onClick={() => handleSendConditional(student.id)}
                          className="bg-indigo-50 text-indigo-600 px-3 py-1 rounded-lg text-[10px] font-bold hover:bg-indigo-100 transition-colors flex items-center gap-1"
                          title="Feltételes Felvételi Küldése"
                        >
                          <ICONS.FileCheck size={14} /> Conditional
                        </button>
                      )}
                      <button onClick={() => setActiveSubView('review')} className="bg-slate-900 text-white px-3 py-1.5 rounded-lg text-[11px] font-bold hover:bg-slate-800 inline-flex items-center gap-1.5">
                        <ICONS.Eye size={13} /> Részletek
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
  };

  const renderFormBuilder = () => (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="lg:col-span-2 space-y-6">
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <div className="flex items-center justify-between mb-8">
            <h3 className="font-bold text-slate-800 text-lg">Jelentkezési Lap Szerkesztő</h3>
            <button className="bg-slate-900 text-white px-4 py-2 rounded-xl text-sm font-bold flex items-center gap-2">
              <ICONS.PlusCircle size={16} /> Új mező hozzáadása
            </button>
          </div>
          
          <div className="space-y-4">
            <div className="p-4 bg-slate-50 rounded-xl border border-slate-200 border-dashed group cursor-move">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="text-slate-300">:::</div>
                  <div>
                    <p className="text-sm font-bold text-slate-700 uppercase tracking-wider">Személyes Adatok Szekció</p>
                  </div>
                </div>
                <div className="flex gap-2 opacity-0 group-hover:opacity-100 transition-opacity">
                  <button className="p-1 text-slate-400 hover:text-indigo-600"><ICONS.Layout size={16} /></button>
                </div>
              </div>
            </div>

            <div className="p-4 bg-white rounded-xl border border-slate-200 flex items-center justify-between group">
              <div className="flex items-center gap-3">
                <div className="text-slate-300">:::</div>
                <div className="w-8 h-8 bg-indigo-50 text-indigo-600 rounded flex items-center justify-center font-bold text-xs">Ab</div>
                <div>
                  <p className="text-sm font-semibold text-slate-800">Legmagasabb iskolai végzettség</p>
                  <p className="text-[10px] text-slate-400 font-bold uppercase">Legördülő Menü • Kötelező</p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span className="px-2 py-1 bg-purple-50 text-purple-600 rounded text-[10px] font-bold flex items-center gap-1">
                  <ICONS.Zap size={10} /> Feltételes Logika
                </span>
                <button className="p-1 text-slate-400 hover:text-red-500"><ICONS.PlusCircle className="rotate-45" size={16} /></button>
              </div>
            </div>

            <div className="p-4 bg-white/50 rounded-xl border border-slate-100 border-dashed ml-12 border-l-4 border-l-purple-200">
               <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <ICONS.FileText size={16} className="text-purple-400" />
                  <div>
                    <p className="text-sm font-semibold text-slate-600 italic">IF 'PhD' THEN: Publikációs lista feltöltése</p>
                  </div>
                </div>
                <button className="text-[10px] font-bold text-indigo-600">Szerkesztés</button>
               </div>
            </div>
          </div>
        </div>
      </div>

      <div className="space-y-6">
        <div className="bg-indigo-50 p-6 rounded-2xl border border-indigo-100">
          <h4 className="font-bold text-indigo-900 mb-4">Működési Segédlet</h4>
          <p className="text-sm text-indigo-700 leading-relaxed">
            Használja a drag-and-drop funkciót a szekciók átrendezéséhez. A feltételes logika lehetővé teszi, hogy csak a releváns kérdések jelenjenek meg a diáknak.
          </p>
          <div className="mt-6 p-4 bg-white rounded-xl border border-indigo-100">
            <p className="text-xs font-bold text-indigo-900 mb-2">Gyors Tipp:</p>
            <p className="text-xs text-indigo-600">A "Submit" gomb automatikusan letiltásra kerül, ha egy kötelező mező üres.</p>
          </div>
        </div>
      </div>
    </div>
  );

  const renderReview = () => (
    <div className="flex flex-col lg:flex-row gap-8 h-[calc(100vh-280px)] animate-in fade-in zoom-in-95 duration-500">
      {/* Student Selection Sidebar (Internal) */}
      <div className="lg:w-64 flex flex-col gap-2 overflow-y-auto border-r border-slate-100 pr-4">
        <h3 className="font-bold text-slate-800 text-xs uppercase tracking-wider mb-2">Jelentkezők</h3>
        {students.map(s => (
          <div 
            key={s.id}
            onClick={() => setSelectedStudentId(s.id)}
            className={`p-3 rounded-xl cursor-pointer transition-all border ${selectedStudentId === s.id ? 'bg-indigo-50 border-indigo-200 shadow-sm' : 'bg-white border-transparent hover:bg-slate-50'}`}
          >
            <p className="text-sm font-bold text-slate-800 truncate">{s.name}</p>
            <p className="text-[10px] text-slate-400 truncate">{s.program}</p>
          </div>
        ))}
      </div>

      {/* File Sidebar */}
      <div className="lg:w-72 flex flex-col gap-4 overflow-y-auto pr-2">
        <div className="mb-4">
          <h3 className="font-bold text-slate-800 text-lg">{selectedStudent?.name || 'Válasszon diákot'}</h3>
          <p className="text-xs text-slate-400">{selectedStudent?.email}</p>
        </div>
        <h3 className="font-bold text-slate-800 text-xs uppercase tracking-wider mb-2">Csatolt Dokumentumok</h3>
        <div className="space-y-3">
          <div className="p-4 bg-white rounded-2xl border-2 border-indigo-500 shadow-sm cursor-pointer">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center">
                <ICONS.ScanLine size={20} />
              </div>
              <div className="flex-1">
                <p className="text-sm font-bold text-slate-800">Útlevél másolat</p>
                <p className="text-[10px] text-emerald-500 font-bold uppercase">AI Szkennelve</p>
              </div>
            </div>
          </div>
          {/* Dynamically show more if needed, but keeping the UI structure */}
          <div className="p-4 bg-white rounded-2xl border border-slate-100 hover:border-indigo-200 shadow-sm cursor-pointer transition-colors group">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 bg-slate-50 text-slate-400 group-hover:bg-indigo-50 group-hover:text-indigo-500 rounded-xl flex items-center justify-center transition-colors">
                <ICONS.FileText size={20} />
              </div>
              <div>
                <p className="text-sm font-bold text-slate-700">Diploma kivonat</p>
                <p className="text-[10px] text-slate-400 font-bold uppercase tracking-tight">PDF • 2.4 MB</p>
              </div>
            </div>
          </div>
        </div>

        <div className="mt-auto pt-6">
          <button className="w-full bg-slate-900 text-white py-4 rounded-2xl font-bold flex items-center justify-center gap-2 shadow-xl shadow-slate-200 hover:bg-black transition-all">
            <ICONS.Download size={20} />
            Egyesített PDF (All-in-One)
          </button>
        </div>
      </div>

      {/* Preview & AI Analysis */}
      <div className="flex-1 bg-white rounded-3xl border border-slate-100 shadow-sm flex flex-col overflow-hidden relative">
        <div className="p-4 border-b border-slate-50 flex items-center justify-between bg-slate-50/50">
          <div className="flex items-center gap-4">
             <span className="text-xs font-bold text-slate-500 uppercase">Oldal 1 / 1</span>
             <div className="flex gap-1">
               <button className="w-8 h-8 bg-white rounded-lg border border-slate-200 flex items-center justify-center hover:bg-slate-50 text-slate-600 transition-colors">-</button>
               <button className="w-8 h-8 bg-white rounded-lg border border-slate-200 flex items-center justify-center hover:bg-slate-50 text-slate-600 transition-colors">+</button>
             </div>
          </div>
          <button 
            onClick={simulateScan}
            className={`flex items-center gap-2 px-4 py-2 rounded-xl text-sm font-bold transition-all ${isScanning ? 'bg-indigo-100 text-indigo-400' : 'bg-indigo-600 text-white shadow-lg shadow-indigo-100'}`}
          >
            <ICONS.ScanLine size={16} />
            {isScanning ? 'Szkennelés...' : 'AI Adatkiolvasás'}
          </button>
        </div>
        
        <div className="flex-1 bg-slate-100 p-8 flex items-center justify-center relative overflow-hidden">
          {/* Mock Document */}
          <div className="w-[500px] h-[700px] bg-white shadow-2xl rounded-sm p-12 relative">
             {isScanning && (
               <div className="absolute top-0 left-0 w-full h-1 bg-indigo-500 shadow-[0_0_15px_rgba(99,102,241,0.5)] animate-scan z-20"></div>
             )}
             <div className="border-b-2 border-slate-900 pb-4 mb-8">
               <h1 className="text-2xl font-serif font-bold uppercase tracking-widest text-slate-900">PASSPORT</h1>
             </div>
             <div className="flex gap-8">
               <div className="w-32 h-40 bg-slate-200 rounded"></div>
               <div className="flex-1 space-y-4">
                 <div className="h-4 bg-slate-100 w-full rounded"></div>
                 <div className="h-4 bg-slate-100 w-3/4 rounded"></div>
                 <div className="h-4 bg-slate-100 w-1/2 rounded"></div>
               </div>
             </div>
          </div>

          {/* AI Result Box */}
          <div className={`absolute bottom-8 right-8 w-80 bg-white/95 backdrop-blur shadow-2xl rounded-2xl p-6 border border-indigo-100 transition-all transform ${isScanning ? 'translate-y-10 opacity-0' : 'translate-y-0 opacity-100'}`}>
            <div className="flex items-center gap-2 mb-4">
              <div className="w-8 h-8 bg-emerald-50 text-emerald-600 rounded-lg flex items-center justify-center">
                <ICONS.CheckCircle size={18} />
              </div>
              <h5 className="font-bold text-slate-800">AI Kiolvasási Eredmény</h5>
            </div>
            <div className="space-y-3">
              <div>
                <p className="text-[10px] text-slate-400 font-bold uppercase">Név</p>
                <p className="text-sm font-semibold text-slate-800">{selectedStudent?.name.toUpperCase() || '---'}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 font-bold uppercase">Születési Dátum</p>
                <p className="text-sm font-semibold text-slate-800">1998.05.12</p>
              </div>
              <div className="pt-2 border-t border-slate-50">
                <p className="text-[10px] text-emerald-500 font-bold">PONTOSSÁG: 99.8%</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );

  const renderOffers = () => (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all">
        <div className="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center mb-4">
          <ICONS.FileCheck size={24} />
        </div>
        <h4 className="font-bold text-slate-800 mb-2">Feltételes Felvételi (Conditional)</h4>
        <p className="text-xs text-slate-400 mb-2">Címzett: <span className="font-bold">{selectedStudent?.name || '---'}</span></p>
        <p className="text-xs text-slate-400 mb-6">Sablon: standard_conditional_v2.pdf</p>
        <button 
          onClick={() => selectedStudent && handleSendConditional(selectedStudent.id)}
          className="w-full flex items-center justify-center gap-2 py-3 bg-indigo-600 text-white rounded-xl font-bold hover:bg-indigo-700 transition-all"
        >
          Generálás & Küldés
        </button>
      </div>
      <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all">
        <div className="w-12 h-12 bg-emerald-50 text-emerald-600 rounded-xl flex items-center justify-center mb-4">
          <ICONS.FileCheck size={24} />
        </div>
        <h4 className="font-bold text-slate-800 mb-2">Végleges Felvételi (Unconditional)</h4>
        <p className="text-xs text-slate-400 mb-2">Címzett: <span className="font-bold">{selectedStudent?.name || '---'}</span></p>
        <p className="text-xs text-slate-400 mb-6">Sablon: final_offer_2024.pdf</p>
        <button className="w-full flex items-center justify-center gap-2 py-3 bg-emerald-600 text-white rounded-xl font-bold hover:bg-emerald-700 transition-all">
          Generálás & Küldés
        </button>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Module Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Jelentkezés és Felvételi</h2>
          <p className="text-slate-500 mt-1">Az Admissions Core modul központosított bírálati felülete.</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="relative">
            <ICONS.Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
            <input type="text" placeholder="ID szerinti keresés..." className="pl-10 pr-4 py-2 bg-white border border-slate-200 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20" />
          </div>
        </div>
      </div>

      {/* Local Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('applications')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'applications' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Jelentkezések
        </button>
        <button 
          onClick={() => setActiveSubView('review')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'review' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Dokumentum Bírálat
        </button>
        <button 
          onClick={() => setActiveSubView('offers')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'offers' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Ajánlatlevél Generátor
        </button>
      </div>

      {/* Dynamic Content */}
      <div className="mt-8">
        {activeSubView === 'applications' && renderApplications()}
        {activeSubView === 'form_builder' && renderFormBuilder()}
        {activeSubView === 'review' && renderReview()}
        {activeSubView === 'offers' && renderOffers()}
      </div>

      <style>{`
        @keyframes scan {
          0% { top: 0; }
          100% { top: 100%; }
        }
        .animate-scan {
          animation: scan 2s linear infinite;
        }
      `}</style>
    </div>
  );
};
return AdmissionsCore;
})();

/* ===== EngagementCRM ===== */
const EngagementCRM = (() => {
type CRMSubView = 'inbox' | 'whatsapp' | 'campaigns' | 'nudges' | 'video' | 'bulk_send' | 'workflows';

interface WorkflowStep {
  id: string;
  type: 'trigger' | 'condition' | 'action';
  label: string;
  description: string;
  icon: keyof typeof ICONS;
}

interface Workflow {
  id: string;
  name: string;
  description: string;
  status: 'Active' | 'Draft' | 'Paused';
  lastRun: string;
  totalProcessed: number;
  successRate: number;
  steps: WorkflowStep[];
}

const mockWorkflows: Workflow[] = [
  {
    id: 'wf-1',
    name: 'Nemzetközi Érdeklődő Gondozás',
    description: 'Automatikus válasz és követés nemzetközi leadek számára.',
    status: 'Active',
    lastRun: '2 perce',
    totalProcessed: 1240,
    successRate: 94,
    steps: [
      { id: 's1', type: 'trigger', label: 'Új Lead', description: 'Amikor új nemzetközi lead érkezik', icon: 'Target' },
      { id: 's2', type: 'condition', label: 'Ország Ellenőrzés', description: 'Ha az ország nem EU-s', icon: 'Globe' },
      { id: 's3', type: 'action', label: 'Vízum Tájékoztató', description: 'Email küldése a vízum folyamatról', icon: 'Mail' }
    ]
  },
  {
    id: 'wf-2',
    name: 'Hiányzó Dokumentum Követés',
    description: 'Emlékeztetők küldése, ha a jelentkezés hiányos.',
    status: 'Active',
    lastRun: '1 órája',
    totalProcessed: 850,
    successRate: 88,
    steps: [
      { id: 's1', type: 'trigger', label: 'Státusz: Missing Info', description: 'Amikor a státusz Missing Info-ra vált', icon: 'AlertCircle' },
      { id: 's2', type: 'action', label: 'WhatsApp Értesítés', description: 'Azonnali üzenet a hiányzó elemekről', icon: 'Smartphone' },
      { id: 's3', type: 'action', label: 'Email Emlékeztető', description: 'Részletes lista küldése 24 óra múlva', icon: 'Mail' }
    ]
  }
];

const mockMessages: Message[] = [
  { id: '1', sender: 'Al-Farabi Ammar', content: 'Köszönöm a tájékoztatást, feltöltöttem a hiányzó diplomát.', timestamp: '10:45', type: 'Email', direction: 'Incoming' },
  { id: '2', sender: 'Rendszer', content: 'Automatikus emlékeztető kiküldve: Tandíj befizetés határideje.', timestamp: 'Tegnap', type: 'System', direction: 'Outgoing' },
  { id: '3', sender: 'Kovács Ádám', content: 'Mikor várható a végleges felvételi döntés?', timestamp: 'Hétfő', type: 'WhatsApp', direction: 'Incoming' },
];

const EngagementCRM: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<CRMSubView>('inbox');
  const [selectedWorkflowId, setSelectedWorkflowId] = useState<string | null>(null);
  const [isVideoRecording, setIsVideoRecording] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const { data: campaigns, isLoading: campaignsLoading, refresh: refreshCampaigns } = useApi(api.getCampaigns);
  const { data: students, isLoading: studentsLoading } = useApi(api.getStudents);
  
  const [selectedStatus, setSelectedStatus] = useState<string>('All');
  const [bulkEmailSubject, setBulkEmailSubject] = useState('');
  const [bulkEmailBody, setBulkEmailBody] = useState('');
  const [isSending, setIsSending] = useState(false);
  const [sendSuccess, setSendSuccess] = useState(false);
  const [messageText, setMessageText] = useState('');
  const [activeChannel, setActiveChannel] = useState<'Email' | 'WhatsApp'>('Email');

  const whatsappStudents = students?.filter(s => !!s.phone) || [];
  const [whatsappSearch, setWhatsappSearch] = useState('');
  const filteredWhatsappStudents = whatsappStudents.filter(s => 
    s.name.toLowerCase().includes(whatsappSearch.toLowerCase()) || 
    s.phone?.includes(whatsappSearch)
  );

  const filteredStudents = students?.filter(s => selectedStatus === 'All' || s.status === selectedStatus) || [];

  const handleSendMessage = async (channel: 'Email' | 'WhatsApp') => {
    if (!messageText || !selectedStudent) return;
    
    setIsSending(true);
    try {
      if (channel === 'WhatsApp') {
        // In a real app, we'd use the student's phone number
        // For the demo, we'll use a placeholder or the student's email as a mock "to"
        await api.sendWhatsAppMessage({
          to: selectedStudent.phone || '36301234567', 
          text: messageText
        });
      } else {
        // Mock email sending
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
      
      // Add message to local state for immediate feedback
      mockMessages.push({
        id: Date.now().toString(),
        sender: 'Rendszer',
        content: messageText,
        timestamp: 'Most',
        type: channel,
        direction: 'Outgoing'
      });
      
      setMessageText('');
    } catch (error) {
      console.error('Failed to send message:', error);
      alert('Hiba történt az üzenet küldésekor.');
    } finally {
      setIsSending(false);
    }
  };

  const handleSendBulkEmail = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!bulkEmailSubject || !bulkEmailBody || filteredStudents.length === 0) return;
    
    setIsSending(true);
    try {
      // Mock API call for sending bulk email
      // In a real app, we'd have api.sendBulkEmail({ status: selectedStatus, subject, body })
      await new Promise(resolve => setTimeout(resolve, 1500));
      
      setSendSuccess(true);
      setTimeout(() => {
        setSendSuccess(false);
        setBulkEmailSubject('');
        setBulkEmailBody('');
        setActiveSubView('campaigns');
        refreshCampaigns();
      }, 2000);
    } catch (error) {
      console.error('Failed to send bulk email:', error);
    } finally {
      setIsSending(false);
    }
  };

  const startVideoRecord = () => {
    setIsVideoRecording(true);
    // Simulation logic
  };

  const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
  const selectedStudent = students?.find(s => s.id === selectedStudentId) || students?.[0];

  const renderInbox = () => (
    <div className="flex bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden h-[calc(100vh-280px)] animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Inbox Sidebar */}
      <div className="w-80 border-r border-slate-50 flex flex-col">
        <div className="p-4 border-b border-slate-50">
          <div className="relative">
            <ICONS.Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={14} />
            <input type="text" placeholder="Beszélgetés keresése..." className="w-full pl-9 pr-4 py-2 bg-slate-50 border-none rounded-xl text-xs focus:ring-2 focus:ring-indigo-500/20" />
          </div>
        </div>
        <div className="flex-1 overflow-y-auto">
          {students?.map((student, i) => (
            <div 
              key={student.id} 
              onClick={() => setSelectedStudentId(student.id)}
              className={`p-4 cursor-pointer hover:bg-slate-50 transition-colors border-l-4 ${(selectedStudentId === student.id || (!selectedStudentId && i === 0)) ? 'bg-indigo-50/30 border-indigo-500' : 'border-transparent'}`}
            >
              <div className="flex justify-between items-start mb-1">
                <p className="font-bold text-sm text-slate-800">{student.name}</p>
                <span className="text-[10px] text-slate-400 font-medium">10:45</span>
              </div>
              <p className="text-xs text-slate-500 truncate">{student.program}</p>
              <div className="flex items-center gap-1 mt-2">
                <ICONS.Mail size={12} className="text-indigo-400" />
                <span className="text-[10px] font-bold uppercase tracking-tighter text-slate-400">Email</span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Chat Area */}
      <div className="flex-1 flex flex-col bg-slate-50/30">
        <div className="p-4 bg-white border-b border-slate-50 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-full bg-indigo-100 flex items-center justify-center font-bold text-indigo-600">
              {selectedStudent?.name.charAt(0) || '?'}
            </div>
            <div>
              <p className="font-bold text-slate-800 text-sm">{selectedStudent?.name || 'Válasszon beszélgetést'}</p>
              <p className="text-[10px] text-emerald-500 font-bold uppercase">Online</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <button className="p-2 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-lg transition-all">
              <ICONS.History size={18} />
            </button>
            <button className="p-2 text-slate-400 hover:text-indigo-600 hover:bg-indigo-50 rounded-lg transition-all">
              <ICONS.MoreVertical size={18} />
            </button>
          </div>
        </div>

        <div className="flex-1 overflow-y-auto p-6 space-y-6">
          <div className="flex justify-center">
            <span className="bg-slate-100 text-slate-400 text-[10px] font-bold px-3 py-1 rounded-full uppercase tracking-widest">Ma</span>
          </div>
          
          {mockMessages.map((msg) => (
            <div key={msg.id} className={`flex ${msg.direction === 'Outgoing' ? 'justify-end' : 'justify-start'}`}>
              <div className={`max-w-[70%] p-4 rounded-2xl shadow-sm ${
                msg.direction === 'Outgoing' 
                  ? 'bg-indigo-600 text-white rounded-tr-none' 
                  : 'bg-white border border-slate-100 text-slate-800 rounded-tl-none'
              }`}>
                {msg.type === 'System' && <p className="text-[10px] font-bold uppercase mb-1 opacity-70">Rendszerüzenet</p>}
                <p className="text-sm leading-relaxed">{msg.content}</p>
                <div className={`flex items-center gap-1 mt-2 ${msg.direction === 'Outgoing' ? 'justify-end' : 'justify-start'}`}>
                  <span className={`text-[10px] ${msg.direction === 'Outgoing' ? 'text-indigo-200' : 'text-slate-400'}`}>{msg.timestamp}</span>
                  {msg.direction === 'Outgoing' && <ICONS.CheckCircle size={10} className="text-indigo-300" />}
                </div>
              </div>
            </div>
          ))}
        </div>

        <div className="p-4 bg-white border-t border-slate-50">
          <div className="flex items-end gap-3 max-w-4xl mx-auto bg-slate-50 rounded-2xl p-2 border border-slate-100">
            <button className="p-3 text-slate-400 hover:text-indigo-600"><ICONS.Paperclip size={20} /></button>
            <textarea 
              placeholder="Email válasz írása..."
              value={messageText}
              onChange={(e) => setMessageText(e.target.value)}
              className="flex-1 bg-transparent border-none focus:ring-0 text-sm py-3 min-h-[44px] max-h-32 resize-none"
            />
            <div className="flex items-center gap-2 p-1">
              <button 
                onClick={() => setActiveSubView('video')}
                className="p-3 text-slate-400 hover:text-indigo-600 bg-white rounded-xl shadow-sm border border-slate-100"
              >
                <ICONS.Video size={20} />
              </button>
              <button 
                onClick={() => handleSendMessage('Email')}
                disabled={isSending || !messageText}
                className="p-3 bg-indigo-600 text-white rounded-xl shadow-lg shadow-indigo-200 hover:bg-indigo-700 transition-all disabled:opacity-50"
              >
                {isSending ? (
                  <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                ) : (
                  <ICONS.Send size={20} />
                )}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );

  const renderWhatsApp = () => (
    <div className="flex bg-white rounded-3xl border border-slate-100 shadow-xl overflow-hidden h-[calc(100vh-280px)] animate-in fade-in zoom-in-95 duration-500">
      {/* Messenger Sidebar */}
      <div className="w-96 border-r border-slate-100 flex flex-col bg-white">
        <div className="p-6 space-y-4">
          <div className="flex items-center justify-between">
            <h3 className="text-2xl font-black text-slate-900 tracking-tight">Csevegések</h3>
            <div className="flex gap-2">
              <button className="p-2 bg-slate-100 rounded-full text-slate-600 hover:bg-slate-200 transition-colors">
                <ICONS.MoreHorizontal size={20} />
              </button>
              <button className="p-2 bg-slate-100 rounded-full text-slate-600 hover:bg-slate-200 transition-colors">
                <ICONS.Edit3 size={20} />
              </button>
            </div>
          </div>
          <div className="relative">
            <ICONS.Search className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" size={18} />
            <input 
              type="text" 
              placeholder="Keresés a Messengerben" 
              value={whatsappSearch}
              onChange={(e) => setWhatsappSearch(e.target.value)}
              className="w-full pl-12 pr-4 py-3 bg-slate-100 border-none rounded-full text-sm focus:ring-2 focus:ring-indigo-500/20 transition-all" 
            />
          </div>
        </div>

        <div className="flex-1 overflow-y-auto px-2 pb-4">
          {filteredWhatsappStudents.length > 0 ? (
            filteredWhatsappStudents.map((student) => (
              <div 
                key={student.id} 
                onClick={() => {
                  setSelectedStudentId(student.id);
                  setActiveChannel('WhatsApp');
                }}
                className={`flex items-center gap-3 p-3 rounded-2xl cursor-pointer transition-all group ${selectedStudentId === student.id ? 'bg-indigo-50/50' : 'hover:bg-slate-50'}`}
              >
                <div className="relative">
                  <div className="w-14 h-14 rounded-full bg-gradient-to-tr from-indigo-500 to-purple-500 flex items-center justify-center text-white font-bold text-lg shadow-inner">
                    {student.name.charAt(0)}
                  </div>
                  <div className="absolute bottom-0.5 right-0.5 w-4 h-4 bg-emerald-500 border-4 border-white rounded-full"></div>
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex justify-between items-baseline">
                    <p className="font-bold text-slate-800 truncate">{student.name}</p>
                    <span className="text-[11px] text-slate-400 font-medium">14:20</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <p className={`text-xs truncate ${selectedStudentId === student.id ? 'text-indigo-600 font-semibold' : 'text-slate-500'}`}>
                      {student.phone} • Aktív most
                    </p>
                    {selectedStudentId !== student.id && <div className="w-2.5 h-2.5 bg-indigo-600 rounded-full"></div>}
                  </div>
                </div>
              </div>
            ))
          ) : (
            <div className="flex flex-col items-center justify-center h-full text-center p-8">
              <div className="w-16 h-16 bg-slate-50 rounded-full flex items-center justify-center text-slate-300 mb-4">
                <ICONS.MessageSquare size={32} />
              </div>
              <p className="text-sm font-bold text-slate-400">Nincs találat</p>
            </div>
          )}
        </div>
      </div>

      {/* Chat Area */}
      {selectedStudent && selectedStudent.phone ? (
        <div className="flex-1 flex flex-col bg-white">
          {/* Chat Header */}
          <div className="px-6 py-4 border-b border-slate-100 flex items-center justify-between bg-white/80 backdrop-blur-md sticky top-0 z-10">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-full bg-slate-100 flex items-center justify-center font-bold text-slate-600">
                {selectedStudent.name.charAt(0)}
              </div>
              <div>
                <p className="font-bold text-slate-900 text-sm">{selectedStudent.name}</p>
                <p className="text-[11px] text-emerald-500 font-bold">Aktív most</p>
              </div>
            </div>
            <div className="flex items-center gap-4 text-indigo-600">
              <button className="p-2 hover:bg-slate-100 rounded-full transition-colors"><ICONS.Phone size={20} /></button>
              <button className="p-2 hover:bg-slate-100 rounded-full transition-colors"><ICONS.Video size={20} /></button>
              <button className="p-2 hover:bg-slate-100 rounded-full transition-colors"><ICONS.Info size={20} /></button>
            </div>
          </div>

          {/* Messages Area */}
          <div className="flex-1 overflow-y-auto p-6 space-y-4 bg-white">
            <div className="flex flex-col items-center py-10 space-y-2">
              <div className="w-20 h-20 rounded-full bg-slate-100 flex items-center justify-center text-slate-400 mb-2">
                <ICONS.User size={40} />
              </div>
              <h4 className="font-black text-xl text-slate-900">{selectedStudent.name}</h4>
              <p className="text-xs text-slate-500">WhatsApp • {selectedStudent.phone}</p>
              <button className="mt-4 px-4 py-2 bg-slate-100 rounded-lg text-xs font-bold text-slate-700 hover:bg-slate-200 transition-all">Profil megtekintése</button>
            </div>

            {mockMessages.filter(m => m.type === 'WhatsApp').map((msg) => (
              <div key={msg.id} className={`flex ${msg.direction === 'Outgoing' ? 'justify-end' : 'justify-start'}`}>
                <div className="flex items-end gap-2 max-w-[75%]">
                  {msg.direction === 'Incoming' && (
                    <div className="w-7 h-7 rounded-full bg-slate-200 flex-shrink-0 flex items-center justify-center text-[10px] font-bold">
                      {selectedStudent.name.charAt(0)}
                    </div>
                  )}
                  <div className={`p-3 px-4 rounded-3xl text-sm ${
                    msg.direction === 'Outgoing' 
                      ? 'bg-indigo-600 text-white rounded-br-none' 
                      : 'bg-slate-100 text-slate-800 rounded-bl-none'
                  }`}>
                    <p className="leading-relaxed">{msg.content}</p>
                  </div>
                </div>
              </div>
            ))}
          </div>

          {/* Input Area */}
          <div className="p-4 bg-white">
            <div className="flex items-center gap-2 max-w-5xl mx-auto">
              <div className="flex items-center gap-1 text-indigo-600">
                <button className="p-2 hover:bg-slate-100 rounded-full"><ICONS.PlusCircle size={24} /></button>
                <button className="p-2 hover:bg-slate-100 rounded-full"><ICONS.Image size={24} /></button>
                <button className="p-2 hover:bg-slate-100 rounded-full"><ICONS.StickyNote size={24} /></button>
                <button className="p-2 hover:bg-slate-100 rounded-full"><ICONS.Mic size={24} /></button>
              </div>
              <div className="flex-1 relative">
                <input 
                  type="text" 
                  placeholder="Üzenet küldése..." 
                  value={messageText}
                  onChange={(e) => setMessageText(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && handleSendMessage('WhatsApp')}
                  className="w-full bg-slate-100 border-none rounded-full px-5 py-3 text-sm focus:ring-2 focus:ring-indigo-500/20 transition-all"
                />
                <button className="absolute right-3 top-1/2 -translate-y-1/2 text-indigo-600 hover:scale-110 transition-transform">
                  <ICONS.Smile size={20} />
                </button>
              </div>
              <button 
                onClick={() => handleSendMessage('WhatsApp')}
                disabled={isSending || !messageText}
                className={`p-2 rounded-full transition-all ${messageText ? 'text-indigo-600 hover:bg-indigo-50' : 'text-slate-300'}`}
              >
                {isSending ? (
                  <div className="w-6 h-6 border-2 border-indigo-600 border-t-transparent rounded-full animate-spin"></div>
                ) : (
                  <ICONS.Send size={24} />
                )}
              </button>
            </div>
          </div>
        </div>
      ) : (
        <div className="flex-1 flex flex-col items-center justify-center bg-white p-12 text-center">
          <div className="w-24 h-24 bg-indigo-50 rounded-full flex items-center justify-center text-indigo-200 mb-6">
            <ICONS.MessageCircle size={48} />
          </div>
          <h4 className="text-2xl font-black text-slate-900">Válasszon egy beszélgetést</h4>
          <p className="text-slate-500 mt-2 max-w-sm">Kattintson a bal oldali listából egy hallgatóra, hogy megkezdje a WhatsApp csevegést.</p>
          <button className="mt-8 px-8 py-3 bg-indigo-600 text-white rounded-2xl font-bold shadow-xl shadow-indigo-100 hover:bg-indigo-700 transition-all">
            Új üzenet írása
          </button>
        </div>
      )}
    </div>
  );

  const renderCampaigns = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex justify-between items-center">
        <h3 className="text-xl font-bold text-slate-800">Korábbi Kampányok</h3>
        <button 
          onClick={() => setActiveSubView('bulk_send')}
          className="bg-indigo-600 text-white px-5 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all flex items-center gap-2"
        >
          <ICONS.PlusCircle size={18} /> Új Tömeges Küldés
        </button>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {campaigns?.map(camp => (
          <div key={camp.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all">
            <div className="flex justify-between items-start mb-4">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${camp.status === 'Sent' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-400'}`}>
                <ICONS.BarChart2 size={20} />
              </div>
              <span className={`text-[10px] font-bold px-2 py-1 rounded-md uppercase ${camp.status === 'Sent' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-500'}`}>
                {camp.status}
              </span>
            </div>
            <h4 className="font-bold text-slate-800 mb-1">{camp.title}</h4>
            <p className="text-xs text-slate-400 mb-6">{camp.segment}</p>
            
            <div className="space-y-3">
              <div className="flex justify-between text-xs font-semibold">
                <span className="text-slate-500">Megnyitási arány</span>
                <span className="text-indigo-600">{camp.openRate}%</span>
              </div>
              <div className="w-full bg-slate-100 h-2 rounded-full overflow-hidden">
                <div className="bg-indigo-600 h-full transition-all duration-1000" style={{ width: `${camp.openRate}%` }}></div>
              </div>
              <div className="flex justify-between text-[10px] text-slate-400 font-bold uppercase">
                <span>Kiküldve: {camp.sentCount} fő</span>
                <button className="text-indigo-600 hover:underline">Részletek</button>
              </div>
            </div>
          </div>
        ))}
        <button className="border-2 border-dashed border-slate-200 rounded-2xl flex flex-col items-center justify-center p-6 text-slate-400 hover:border-indigo-400 hover:text-indigo-500 hover:bg-indigo-50/30 transition-all group">
          <ICONS.PlusCircle size={32} className="mb-2 group-hover:scale-110 transition-transform" />
          <span className="font-bold text-sm">Új Kampány Létrehozása</span>
        </button>
      </div>
    </div>
  );

  const renderNudges = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-8 border-b border-slate-50">
          <h3 className="text-xl font-bold text-slate-800">Automatikus Emlékeztetők (Nudges)</h3>
          <p className="text-sm text-slate-400 mt-1">Ezek az üzenetek automatikusan kiküldésre kerülnek bizonyos feltételek teljesülésekor.</p>
        </div>
        <div className="divide-y divide-slate-50">
          {[
            { title: 'Befejezetlen jelentkezés', trigger: '3 nap inaktivitás után', channel: 'Email + WhatsApp', active: true },
            { title: 'Hiányzó dokumentum', trigger: 'Beküldés után azonnal', channel: 'Email', active: true },
            { title: 'Tandíj határidő közeleg', trigger: '7 nappal a határidő előtt', channel: 'Email + SMS', active: false },
          ].map((rule, i) => (
            <div key={i} className="p-6 flex items-center justify-between hover:bg-slate-50 transition-colors">
              <div className="flex items-center gap-4">
                <div className={`w-12 h-12 rounded-2xl flex items-center justify-center ${rule.active ? 'bg-indigo-50 text-indigo-600' : 'bg-slate-100 text-slate-400'}`}>
                  <ICONS.Zap size={24} />
                </div>
                <div>
                  <h4 className="font-bold text-slate-800">{rule.title}</h4>
                  <div className="flex items-center gap-3 mt-1">
                    <span className="text-xs text-slate-400 flex items-center gap-1"><ICONS.Clock size={12} /> {rule.trigger}</span>
                    <span className="text-xs text-slate-400 flex items-center gap-1"><ICONS.Smartphone size={12} /> {rule.channel}</span>
                  </div>
                </div>
              </div>
              <div className="flex items-center gap-4">
                <div className={`w-12 h-6 rounded-full relative cursor-pointer transition-colors ${rule.active ? 'bg-emerald-500' : 'bg-slate-300'}`}>
                  <div className={`absolute top-1 w-4 h-4 bg-white rounded-full transition-all ${rule.active ? 'right-1' : 'left-1'}`} />
                </div>
                <button className="p-2 text-slate-300 hover:text-slate-600 transition-colors"><ICONS.Settings size={18} /></button>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  const renderVideoMessage = () => (
    <div className="max-w-4xl mx-auto animate-in zoom-in-95 duration-500">
      <div className="bg-slate-900 rounded-3xl overflow-hidden shadow-2xl aspect-video relative group">
        {!isVideoRecording ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center text-white bg-slate-900/40 backdrop-blur-sm">
            <div className="w-20 h-20 bg-white/10 rounded-full flex items-center justify-center mb-4 hover:scale-110 transition-transform cursor-pointer border border-white/20" onClick={startVideoRecord}>
              <ICONS.Video size={32} className="text-white" />
            </div>
            <h3 className="text-xl font-bold">Személyes Videoüzenet Rögzítése</h3>
            <p className="text-slate-400 text-sm mt-2">Kattintson az indításhoz és rögzítsen egy köszöntőt.</p>
          </div>
        ) : (
          <div className="absolute inset-0">
             <div className="absolute top-6 left-6 flex items-center gap-2 bg-red-600 px-3 py-1 rounded-full animate-pulse">
               <div className="w-2 h-2 bg-white rounded-full" />
               <span className="text-[10px] font-bold text-white uppercase tracking-widest">Rec 00:12</span>
             </div>
             {/* Mock Video Feed */}
             <div className="w-full h-full bg-slate-800 flex items-center justify-center">
               <div className="w-48 h-48 rounded-full border-4 border-white/10 flex items-center justify-center">
                  <ICONS.Users size={64} className="text-white/20" />
               </div>
             </div>
             <div className="absolute bottom-8 left-1/2 -translate-x-1/2 flex items-center gap-4">
                <button onClick={() => setIsVideoRecording(false)} className="bg-white text-slate-900 px-8 py-3 rounded-2xl font-bold hover:bg-slate-100 shadow-xl transition-all">
                  Rögzítés leállítása
                </button>
             </div>
          </div>
        )}
      </div>
      <div className="mt-8 grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <h4 className="font-bold text-slate-800 mb-2">Videoüzenet előnyei</h4>
          <p className="text-sm text-slate-500 leading-relaxed">A személyre szabott videóüzenetek akár 40%-kal növelik a beiratkozási kedvet a Z-generációs diákok körében.</p>
        </div>
        <div className="bg-indigo-50 p-6 rounded-2xl border border-indigo-100">
          <h4 className="font-bold text-indigo-900 mb-2">Használati Tipp</h4>
          <p className="text-sm text-indigo-700 leading-relaxed">Használja a videót gratulációhoz vagy ha a diák elakadt a jelentkezési folyamatban.</p>
        </div>
      </div>
    </div>
  );

  const renderBulkSend = () => (
    <div className="max-w-4xl mx-auto space-y-8 animate-in zoom-in-95 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm space-y-8">
        <div className="flex items-center gap-4">
          <div className="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center">
            <ICONS.Send size={24} />
          </div>
          <div>
            <h3 className="text-xl font-bold text-slate-800">Új Tömeges E-mail Küldése</h3>
            <p className="text-sm text-slate-400 mt-1">Válassza ki a célcsoportot státusz alapján.</p>
          </div>
        </div>

        <form onSubmit={handleSendBulkEmail} className="space-y-6">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Célcsoport (Státusz)</label>
              <select 
                value={selectedStatus}
                onChange={(e) => setSelectedStatus(e.target.value)}
                className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20 transition-all"
              >
                <option value="All">Összes jelentkező ({students?.length || 0})</option>
                <option value="Draft">Draft ({students?.filter(s => s.status === 'Draft').length || 0})</option>
                <option value="Submitted">Submitted ({students?.filter(s => s.status === 'Submitted').length || 0})</option>
                <option value="Accepted">Accepted ({students?.filter(s => s.status === 'Accepted').length || 0})</option>
                <option value="Paid">Paid ({students?.filter(s => s.status === 'Paid').length || 0})</option>
                <option value="Missing Info">Missing Info ({students?.filter(s => s.status === 'Missing Info').length || 0})</option>
              </select>
            </div>
            <div className="flex items-end">
              <div className="bg-indigo-50 p-4 rounded-2xl border border-indigo-100 w-full">
                <p className="text-xs text-indigo-700 font-medium">
                  Kiválasztott címzettek száma: <span className="font-bold">{filteredStudents.length} fő</span>
                </p>
              </div>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">E-mail Tárgya</label>
              <input 
                type="text" 
                value={bulkEmailSubject}
                onChange={(e) => setBulkEmailSubject(e.target.value)}
                placeholder="pl. Fontos tájékoztató a beiratkozásról"
                className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20 transition-all"
                required
              />
            </div>
            <div>
              <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Üzenet Törzse</label>
              <textarea 
                value={bulkEmailBody}
                onChange={(e) => setBulkEmailBody(e.target.value)}
                placeholder="Írja ide az üzenet tartalmát..."
                className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20 transition-all min-h-[200px] resize-none"
                required
              />
            </div>
          </div>

          <div className="flex items-center justify-between pt-4">
            <button 
              type="button"
              onClick={() => setActiveSubView('campaigns')}
              className="px-6 py-3 text-slate-500 font-bold text-sm hover:bg-slate-50 rounded-2xl transition-all"
            >
              Mégse
            </button>
            
            {sendSuccess ? (
              <div className="bg-emerald-50 text-emerald-600 px-6 py-3 rounded-2xl border border-emerald-100 flex items-center gap-2 animate-in zoom-in duration-300">
                <ICONS.CheckCircle size={20} />
                <span className="font-bold">Sikeresen kiküldve!</span>
              </div>
            ) : (
              <button 
                type="submit"
                disabled={isSending || filteredStudents.length === 0}
                className="bg-indigo-600 text-white px-10 py-4 rounded-2xl font-bold shadow-xl shadow-indigo-100 hover:bg-indigo-700 transition-all disabled:opacity-50 flex items-center gap-2"
              >
                {isSending ? (
                  <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                ) : (
                  <>Küldés Indítása</>
                )}
              </button>
            )}
          </div>
        </form>
      </div>

      <div className="bg-slate-50 p-6 rounded-3xl border border-slate-100">
        <h4 className="text-sm font-bold text-slate-700 mb-4 flex items-center gap-2">
          <ICONS.Users size={16} /> Címzettek listája ({filteredStudents.length})
        </h4>
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
          {filteredStudents.slice(0, 9).map(s => (
            <div key={s.id} className="bg-white p-3 rounded-xl border border-slate-100 text-xs flex items-center gap-2">
              <div className="w-6 h-6 rounded-full bg-slate-100 flex items-center justify-center font-bold text-slate-400">
                {s.name.charAt(0)}
              </div>
              <span className="truncate font-medium text-slate-600">{s.name}</span>
            </div>
          ))}
          {filteredStudents.length > 9 && (
            <div className="bg-slate-100 p-3 rounded-xl text-xs flex items-center justify-center text-slate-400 font-bold">
              + {filteredStudents.length - 9} további diák
            </div>
          )}
        </div>
      </div>
    </div>
  );

  const renderWorkflows = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex justify-between items-center">
        <div>
          <h3 className="text-xl font-bold text-slate-800">Automatizált Munkafolyamatok</h3>
          <p className="text-sm text-slate-400 mt-1">Hozzon létre komplex, több lépéses automatizációkat.</p>
        </div>
        <button className="bg-indigo-600 text-white px-5 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all flex items-center gap-2">
          <ICONS.Plus size={18} /> Új Munkafolyamat
        </button>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Workflow List */}
        <div className="lg:col-span-1 space-y-4">
          {mockWorkflows.map(wf => (
            <div 
              key={wf.id}
              onClick={() => setSelectedWorkflowId(wf.id)}
              className={`p-5 rounded-2xl border cursor-pointer transition-all ${selectedWorkflowId === wf.id ? 'bg-white border-indigo-500 shadow-md ring-4 ring-indigo-500/5' : 'bg-white border-slate-100 hover:border-indigo-200 shadow-sm'}`}
            >
              <div className="flex justify-between items-start mb-3">
                <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${wf.status === 'Active' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-400'}`}>
                  <ICONS.GitBranch size={20} />
                </div>
                <span className={`text-[10px] font-bold px-2 py-1 rounded-md uppercase ${wf.status === 'Active' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-500'}`}>
                  {wf.status}
                </span>
              </div>
              <h4 className="font-bold text-slate-800 mb-1">{wf.name}</h4>
              <p className="text-xs text-slate-400 line-clamp-2 mb-4">{wf.description}</p>
              
              <div className="flex items-center justify-between pt-4 border-t border-slate-50">
                <div className="flex items-center gap-3">
                  <div className="text-center">
                    <p className="text-[10px] font-bold text-slate-400 uppercase">Feldolgozva</p>
                    <p className="text-xs font-bold text-slate-700">{wf.totalProcessed}</p>
                  </div>
                  <div className="w-px h-6 bg-slate-100" />
                  <div className="text-center">
                    <p className="text-[10px] font-bold text-slate-400 uppercase">Siker</p>
                    <p className="text-xs font-bold text-emerald-600">{wf.successRate}%</p>
                  </div>
                </div>
                <ICONS.ChevronRight size={16} className="text-slate-300" />
              </div>
            </div>
          ))}
        </div>

        {/* Workflow Builder Preview */}
        <div className="lg:col-span-2 bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden min-h-[500px] flex flex-col">
          {selectedWorkflowId ? (
            <>
              <div className="p-6 border-b border-slate-50 flex justify-between items-center bg-slate-50/50">
                <div className="flex items-center gap-4">
                  <div className="w-12 h-12 bg-white rounded-2xl shadow-sm border border-slate-100 flex items-center justify-center text-indigo-600">
                    <ICONS.GitBranch size={24} />
                  </div>
                  <div>
                    <h4 className="font-bold text-slate-800">{mockWorkflows.find(w => w.id === selectedWorkflowId)?.name}</h4>
                    <p className="text-xs text-slate-400">Utolsó futás: {mockWorkflows.find(w => w.id === selectedWorkflowId)?.lastRun}</p>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <button className="p-2 text-slate-400 hover:text-indigo-600 hover:bg-white rounded-lg transition-all border border-transparent hover:border-slate-100">
                    <ICONS.Pause size={18} />
                  </button>
                  <button className="p-2 text-slate-400 hover:text-indigo-600 hover:bg-white rounded-lg transition-all border border-transparent hover:border-slate-100">
                    <ICONS.Settings size={18} />
                  </button>
                  <button className="bg-slate-900 text-white px-4 py-2 rounded-xl text-xs font-bold hover:bg-black transition-all">
                    Szerkesztés
                  </button>
                </div>
              </div>
              
              <div className="flex-1 p-12 overflow-y-auto bg-[radial-gradient(#e5e7eb_1px,transparent_1px)] [background-size:20px_20px]">
                <div className="flex flex-col items-center space-y-8">
                  {mockWorkflows.find(w => w.id === selectedWorkflowId)?.steps.map((step, idx, arr) => {
                    const Icon = ICONS[step.icon];
                    return (
                      <React.Fragment key={step.id}>
                        <div className="relative group">
                          <div className={`w-64 bg-white p-5 rounded-2xl border-2 shadow-sm transition-all hover:shadow-md ${
                            step.type === 'trigger' ? 'border-indigo-500' : 
                            step.type === 'condition' ? 'border-amber-400' : 'border-emerald-500'
                          }`}>
                            <div className="flex items-center gap-3 mb-2">
                              <div className={`p-2 rounded-lg ${
                                step.type === 'trigger' ? 'bg-indigo-50 text-indigo-600' : 
                                step.type === 'condition' ? 'bg-amber-50 text-amber-600' : 'bg-emerald-50 text-emerald-600'
                              }`}>
                                {Icon && <Icon size={18} />}
                              </div>
                              <span className="text-[10px] font-black uppercase tracking-widest opacity-50">{step.type}</span>
                            </div>
                            <h5 className="font-bold text-slate-800 text-sm">{step.label}</h5>
                            <p className="text-[11px] text-slate-500 mt-1">{step.description}</p>
                          </div>
                          
                          {/* Step Connector */}
                          {idx < arr.length - 1 && (
                            <div className="absolute -bottom-8 left-1/2 -translate-x-1/2 flex flex-col items-center">
                              <div className="w-0.5 h-8 bg-slate-200" />
                              <ICONS.ChevronRight size={14} className="text-slate-300 rotate-90 -mt-1" />
                            </div>
                          )}
                        </div>
                      </React.Fragment>
                    );
                  })}
                  
                  <button className="w-10 h-10 rounded-full border-2 border-dashed border-slate-200 flex items-center justify-center text-slate-300 hover:border-indigo-400 hover:text-indigo-500 hover:bg-indigo-50 transition-all">
                    <ICONS.Plus size={20} />
                  </button>
                </div>
              </div>
            </>
          ) : (
            <div className="flex-1 flex flex-col items-center justify-center p-12 text-center">
              <div className="w-20 h-20 bg-slate-50 rounded-3xl flex items-center justify-center text-slate-200 mb-6">
                <ICONS.GitBranch size={40} />
              </div>
              <h4 className="text-lg font-bold text-slate-800">Válasszon egy munkafolyamatot</h4>
              <p className="text-sm text-slate-400 mt-2 max-w-xs">Kattintson a bal oldali listából egy automatizációra a részletek megtekintéséhez és szerkesztéséhez.</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Module Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Kommunikáció és CRM</h2>
          <p className="text-slate-500 mt-1">Az Engagement modul az egyetemi kapcsolattartás központja.</p>
        </div>
        <div className="flex items-center gap-3">
          <button className="flex items-center gap-2 bg-slate-900 text-white px-5 py-2.5 rounded-xl text-sm font-bold hover:bg-black transition-all">
            <ICONS.Filter size={16} /> Szűrés
          </button>
          <button 
            onClick={() => setActiveSubView('bulk_send')}
            className="flex items-center gap-2 bg-indigo-600 text-white px-6 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all"
          >
            <ICONS.PlusCircle size={18} /> Új tömeges e-mail
          </button>
        </div>
      </div>

      {/* Local Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('inbox')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'inbox' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Egyesített Inbox
        </button>
        <button 
          onClick={() => setActiveSubView('whatsapp')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'whatsapp' ? 'bg-emerald-500 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          WhatsApp (Messenger)
        </button>
        <button 
          onClick={() => setActiveSubView('campaigns')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'campaigns' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Tömeges E-mail
        </button>
        <button 
          onClick={() => setActiveSubView('nudges')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'nudges' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Automatikus Emlékeztetők
        </button>
        <button 
          onClick={() => setActiveSubView('workflows')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'workflows' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Munkafolyamatok
        </button>
        <button 
          onClick={() => setActiveSubView('video')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'video' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Videoüzenet Küldés
        </button>
      </div>

      {/* Dynamic Content */}
      <div className="mt-8">
        {activeSubView === 'inbox' && renderInbox()}
        {activeSubView === 'whatsapp' && renderWhatsApp()}
        {activeSubView === 'campaigns' && renderCampaigns()}
        {activeSubView === 'bulk_send' && renderBulkSend()}
        {activeSubView === 'nudges' && renderNudges()}
        {activeSubView === 'workflows' && renderWorkflows()}
        {activeSubView === 'video' && renderVideoMessage()}
      </div>
    </div>
  );
};
return EngagementCRM;
})();

/* ===== Finance ===== */
const Finance = (() => {
type FinanceSubView = 'payments' | 'deposits' | 'currencies' | 'scholarships' | 'integrations' | 'payment_portal';

const Finance: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<FinanceSubView>('payments');
  const { data: payments, isLoading: paymentsLoading, refresh: refreshPayments } = useApi(api.getPayments);
  const { data: invoices, isLoading: invoicesLoading, refresh: refreshInvoices } = useApi(api.getInvoices);
  const { data: students, isLoading: studentsLoading, refresh: refreshStudents } = useApi(api.getStudents);
  const { data: scholarships, isLoading: scholarshipsLoading } = useApi(api.getScholarships);
  const { data: integrations, isLoading: integrationsLoading } = useApi(api.getIntegrations);

  const [isProcessing, setIsProcessing] = useState<string | null>(null);
  const [paymentMethod, setPaymentMethod] = useState<Record<string, 'card' | 'transfer'>>({});
  const [uploadingFile, setUploadingFile] = useState<string | null>(null);

  // New Payment Modal State
  const [showRecordModal, setShowRecordModal] = useState(false);
  const [newPayment, setNewPayment] = useState<Partial<Payment>>({
    studentName: '',
    type: 'Tuition',
    amount: 0,
    currency: 'EUR',
    status: 'Paid',
    method: 'Bank Transfer'
  });

  const handleRecordPayment = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.addPayment(newPayment);
      setShowRecordModal(false);
      refreshPayments();
      refreshStudents();
      setNewPayment({
        studentName: '',
        type: 'Tuition',
        amount: 0,
        currency: 'EUR',
        status: 'Paid',
        method: 'Bank Transfer'
      });
    } catch (error) {
      console.error('Failed to record payment:', error);
    }
  };

  const handleSimulatePayment = async (studentId: string, amount: number) => {
    setIsProcessing(studentId);
    try {
      await api.processPayment({
        studentId,
        amount,
        method: 'Stripe',
        type: 'Tuition'
      });
      refreshPayments();
      refreshStudents();
    } catch (error) {
      console.error('Payment failed:', error);
    } finally {
      setIsProcessing(null);
    }
  };

  const handleUploadProof = async (studentId: string, amount: number) => {
    setUploadingFile(studentId);
    try {
      // Simulation of file upload and submission
      await new Promise(resolve => setTimeout(resolve, 2000));
      await api.submitBankTransfer({
        studentId,
        amount,
        type: 'Tuition',
        proofName: 'bank_receipt_2024.pdf'
      });
      refreshPayments();
      refreshStudents();
      alert('Bizonylat sikeresen feltöltve! A pénzügyi osztály hamarosan ellenőrzi.');
    } catch (error) {
      console.error('Upload failed:', error);
    } finally {
      setUploadingFile(null);
    }
  };

  const handleVerifyPayment = async (paymentId: string) => {
    try {
      await api.verifyPayment(paymentId);
      refreshPayments();
      refreshStudents();
    } catch (error) {
      console.error('Verification failed:', error);
    }
  };

  const renderStats = () => {
    const totalRevenue = payments?.filter(p => p.status === 'Paid').reduce((sum, p) => sum + p.amount, 0) || 0;
    const pendingAmount = invoices?.filter(i => i.status !== 'Paid').reduce((sum, i) => sum + i.amount, 0) || 0;

    return (
      <div className="grid grid-cols-1 md:grid-cols-4 gap-6 mb-8">
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-4 mb-4">
            <div className="w-10 h-10 bg-emerald-50 text-emerald-600 rounded-xl flex items-center justify-center">
              <ICONS.ArrowUpRight size={20} />
            </div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-wider">Bevétel (Havi)</p>
          </div>
          <h3 className="text-2xl font-bold text-slate-800">€{totalRevenue.toLocaleString()}</h3>
          <p className="text-emerald-500 text-[10px] font-bold mt-1">+14.2% az előző hónaphoz</p>
        </div>
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-4 mb-4">
            <div className="w-10 h-10 bg-amber-50 text-amber-600 rounded-xl flex items-center justify-center">
              <ICONS.Clock size={20} />
            </div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-wider">Függőben lévő</p>
          </div>
          <h3 className="text-2xl font-bold text-slate-800">€{pendingAmount.toLocaleString()}</h3>
          <p className="text-slate-400 text-[10px] font-bold mt-1">{invoices?.length || 0} aktív kintlévőség</p>
        </div>
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-4 mb-4">
            <div className="w-10 h-10 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center">
              <ICONS.CreditCard size={20} />
            </div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-wider">Sikeres App Fees</p>
          </div>
          <h3 className="text-2xl font-bold text-slate-800">{payments?.length || 0} db</h3>
          <p className="text-indigo-500 text-[10px] font-bold mt-1">Stripe & PayPal össz.</p>
        </div>
        <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-4 mb-4">
            <div className="w-10 h-10 bg-slate-50 text-slate-600 rounded-xl flex items-center justify-center">
              <ICONS.RefreshCw size={20} />
            </div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-wider">Átváltási Árfolyam</p>
          </div>
          <h3 className="text-lg font-bold text-slate-800">1 EUR = 394 HUF</h3>
          <p className="text-slate-400 text-[10px] font-bold mt-1">Utolsó frissítés: 1 órája</p>
        </div>
      </div>
    );
  };

  const renderPayments = () => (
    <div className="animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50 flex justify-between items-center">
          <h3 className="font-bold text-slate-800 text-lg">Tranzakciók (Jelentkezési díjak & Tandíjak)</h3>
          <div className="flex gap-2">
            <button className="flex items-center gap-2 bg-indigo-50 text-indigo-600 px-4 py-2 rounded-xl text-xs font-bold hover:bg-indigo-100 transition-colors">
              <ICONS.Download size={14} /> CSV Export
            </button>
          </div>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Diák</th>
                <th className="px-6 py-4">Típus</th>
                <th className="px-6 py-4">Összeg</th>
                <th className="px-6 py-4">Módszer</th>
                <th className="px-6 py-4">Dátum</th>
                <th className="px-6 py-4 text-right">Státusz</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {payments?.map(payment => (
                <tr key={payment.id} className="hover:bg-slate-50 transition-colors group">
                  <td className="px-6 py-4">
                    <p className="font-semibold text-slate-800 text-sm">{payment.studentName}</p>
                    <p className="text-[10px] text-slate-400 font-medium">#{payment.id}</p>
                  </td>
                  <td className="px-6 py-4">
                    <span className="text-xs font-medium text-slate-600">{payment.type}</span>
                  </td>
                  <td className="px-6 py-4">
                    <p className="font-bold text-slate-800 text-sm">
                      {payment.amount.toLocaleString()} {payment.currency}
                    </p>
                  </td>
                  <td className="px-6 py-4">
                    <div className="flex items-center gap-2">
                      <ICONS.Landmark size={12} className="text-slate-400" />
                      <span className="text-xs text-slate-500">{payment.method || '---'}</span>
                    </div>
                  </td>
                  <td className="px-6 py-4">
                    <span className="text-xs text-slate-400">{payment.date}</span>
                  </td>
                  <td className="px-6 py-4 text-right">
                    <div className="flex justify-end items-center gap-2">
                      {payment.status === 'Pending' && payment.method === 'Bank Transfer' && (
                        <button 
                          onClick={() => handleVerifyPayment(payment.id)}
                          className="bg-emerald-600 text-white px-3 py-1 rounded-lg text-[10px] font-bold hover:bg-emerald-700 transition-colors"
                        >
                          Jóváhagyás
                        </button>
                      )}
                      <span className={`px-2 py-1 rounded-md text-[10px] font-bold uppercase ${
                        payment.status === 'Paid' ? 'bg-emerald-50 text-emerald-600' : 
                        payment.status === 'Pending' ? 'bg-amber-50 text-amber-600' : 'bg-red-50 text-red-600'
                      }`}>
                        {payment.status}
                      </span>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  const renderDeposits = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div className="lg:col-span-2">
          <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
             <div className="p-6 border-b border-slate-50 flex justify-between items-center">
              <h3 className="font-bold text-slate-800 text-lg">Tandíj Előlegek (Proforma)</h3>
              <button className="bg-indigo-600 text-white px-4 py-2 rounded-xl text-xs font-bold shadow-lg shadow-indigo-100">
                Új Számla Generálása
              </button>
            </div>
            <div className="divide-y divide-slate-50">
              {invoices?.map(invoice => (
                <div key={invoice.id} className="p-6 flex items-center justify-between hover:bg-slate-50 transition-colors">
                  <div className="flex items-center gap-4">
                    <div className="w-12 h-12 bg-slate-50 rounded-2xl flex items-center justify-center text-slate-400">
                      <ICONS.Receipt size={24} />
                    </div>
                    <div>
                      <h4 className="font-bold text-slate-800 text-sm">{invoice.studentName}</h4>
                      <div className="flex items-center gap-3 mt-1">
                        <span className="text-[10px] text-slate-400 font-bold uppercase">ID: {invoice.id}</span>
                        <span className="text-[10px] text-slate-400 flex items-center gap-1 font-bold uppercase"><ICONS.Clock size={10} /> Esedékesség: {invoice.dueDate}</span>
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-8">
                    <div className="text-right">
                      <p className="font-bold text-slate-800">{invoice.amount.toLocaleString()} {invoice.currency}</p>
                      <span className={`text-[10px] font-bold uppercase ${
                        invoice.status === 'Paid' ? 'text-emerald-500' : 
                        invoice.status === 'Overdue' ? 'text-red-500' : 'text-amber-500'
                      }`}>
                        {invoice.status}
                      </span>
                    </div>
                    <div className="flex gap-2">
                      <button className="p-2 text-slate-400 hover:text-indigo-600 bg-white border border-slate-100 rounded-lg shadow-sm">
                        <ICONS.Eye size={16} />
                      </button>
                      <button className="p-2 text-slate-400 hover:text-indigo-600 bg-white border border-slate-100 rounded-lg shadow-sm">
                        <ICONS.Download size={16} />
                      </button>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className="space-y-6">
          <div className="bg-indigo-900 rounded-3xl p-8 text-white shadow-xl">
            <h4 className="font-bold text-xl mb-4">Automatizáció</h4>
            <div className="space-y-4">
              <div className="flex items-center gap-3 p-3 bg-white/10 rounded-xl border border-white/10">
                <ICONS.CheckCircle size={18} className="text-emerald-400" />
                <p className="text-xs">Sikeres befizetés esetén automatikus "Fizetve" státusz frissítés.</p>
              </div>
              <div className="flex items-center gap-3 p-3 bg-white/10 rounded-xl border border-white/10">
                <ICONS.CheckCircle size={18} className="text-emerald-400" />
                <p className="text-xs">Proforma számla automatikus PDF generálása felvétel után.</p>
              </div>
              <div className="flex items-center gap-3 p-3 bg-white/10 rounded-xl border border-white/10">
                <ICONS.AlertCircle size={18} className="text-amber-400" />
                <p className="text-xs">Emlékeztető küldése 3 nappal a lejárat előtt.</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );

  const renderCurrencies = () => (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {['EUR', 'USD', 'HUF'].map((cur) => (
        <div key={cur} className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm relative overflow-hidden group">
          <div className="absolute -right-4 -top-4 w-24 h-24 bg-slate-50 rounded-full flex items-center justify-center text-slate-100 font-black text-5xl group-hover:text-indigo-50 transition-colors">
            {cur.charAt(0)}
          </div>
          <div className="relative z-10">
            <div className="flex items-center gap-3 mb-6">
              <div className="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center">
                <ICONS.Coins size={24} />
              </div>
              <h4 className="font-bold text-slate-800 text-xl">{cur}</h4>
            </div>
            <div className="space-y-3">
              <div className="flex justify-between items-center text-sm">
                <span className="text-slate-400 font-medium">Alapértelmezett díjak</span>
                <span className="text-slate-800 font-bold">{cur === 'HUF' ? 'Nem' : 'Igen'}</span>
              </div>
              <div className="flex justify-between items-center text-sm">
                <span className="text-slate-400 font-medium">Aktív árfolyam</span>
                <span className="text-indigo-600 font-bold">1.00 {cur}</span>
              </div>
            </div>
            <button className="w-full mt-8 py-3 bg-slate-50 text-slate-600 rounded-xl text-sm font-bold hover:bg-indigo-50 hover:text-indigo-600 transition-all">
              Beállítások módosítása
            </button>
          </div>
        </div>
      ))}
    </div>
  );

  const renderScholarships = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex justify-between items-center">
        <div>
          <h3 className="text-xl font-bold text-slate-800">Ösztöndíjak és Kedvezmények</h3>
          <p className="text-sm text-slate-400 mt-1">Kezelje az automatikusan vagy manuálisan kiosztható tandíjkedvezményeket.</p>
        </div>
        <button className="bg-indigo-600 text-white px-5 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all flex items-center gap-2">
          <ICONS.Plus size={18} /> Új Ösztöndíj
        </button>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {scholarships?.map(sch => (
          <div key={sch.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:border-indigo-200 transition-all">
            <div className="flex justify-between items-start mb-4">
              <div className="w-10 h-10 bg-amber-50 text-amber-600 rounded-xl flex items-center justify-center">
                <ICONS.Star size={20} />
              </div>
              <span className={`text-[10px] font-bold px-2 py-1 rounded-md uppercase ${sch.status === 'Active' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-500'}`}>
                {sch.status}
              </span>
            </div>
            <h4 className="font-bold text-slate-800 mb-1">{sch.name}</h4>
            <p className="text-xs text-slate-400 mb-4">{sch.criteria}</p>
            
            <div className="flex items-center justify-between pt-4 border-t border-slate-50">
              <div className="text-lg font-black text-indigo-600">
                {sch.type === 'Percentage' ? `-${sch.value}%` : `-${sch.value} EUR`}
              </div>
              <button className="text-slate-400 hover:text-indigo-600 transition-colors">
                <ICONS.Settings size={16} />
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );

  const renderIntegrations = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div>
        <h3 className="text-xl font-bold text-slate-800">Külső Integrációk</h3>
        <p className="text-sm text-slate-400 mt-1">Kapcsolja össze az UniPortal Pro-t fizetési kapukkal és számlázó rendszerekkel.</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
        {/* Payment Gateways */}
        <div className="space-y-4">
          <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Fizetési Kapuk</h4>
          {integrations?.filter(i => ['Stripe', 'PayPal', 'Wise'].includes(i.provider)).map(int => (
            <div key={int.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className={`w-12 h-12 rounded-2xl flex items-center justify-center ${
                  int.provider === 'Stripe' ? 'bg-indigo-50 text-indigo-600' : 
                  int.provider === 'PayPal' ? 'bg-blue-50 text-blue-600' : 'bg-emerald-50 text-emerald-600'
                }`}>
                  <ICONS.CreditCard size={24} />
                </div>
                <div>
                  <h5 className="font-bold text-slate-800">{int.provider}</h5>
                  <div className="flex items-center gap-2 mt-1">
                    <span className={`w-2 h-2 rounded-full ${
                      int.status === 'Connected' ? 'bg-emerald-500' : 
                      int.status === 'Error' ? 'bg-red-500' : 'bg-slate-300'
                    }`} />
                    <span className="text-[10px] font-bold text-slate-400 uppercase">{int.status}</span>
                    <span className="text-[10px] text-slate-300">•</span>
                    <span className="text-[10px] font-bold text-slate-400 uppercase">{int.mode} MODE</span>
                  </div>
                </div>
              </div>
              <button className="bg-slate-50 text-slate-600 px-4 py-2 rounded-xl text-xs font-bold hover:bg-slate-100 transition-colors">
                Konfigurálás
              </button>
            </div>
          ))}
        </div>

        {/* Invoicing Systems */}
        <div className="space-y-4">
          <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Számlázó Rendszerek</h4>
          {integrations?.filter(i => ['Billingo', 'Szamlazz.hu'].includes(i.provider)).map(int => (
            <div key={int.id} className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="w-12 h-12 bg-slate-50 text-slate-600 rounded-2xl flex items-center justify-center">
                  <ICONS.FileText size={24} />
                </div>
                <div>
                  <h5 className="font-bold text-slate-800">{int.provider}</h5>
                  <div className="flex items-center gap-2 mt-1">
                    <span className={`w-2 h-2 rounded-full ${
                      int.status === 'Connected' ? 'bg-emerald-500' : 'bg-slate-300'
                    }`} />
                    <span className="text-[10px] font-bold text-slate-400 uppercase">{int.status}</span>
                    {int.lastSync && (
                      <>
                        <span className="text-[10px] text-slate-300">•</span>
                        <span className="text-[10px] text-slate-400">Utolsó szinkron: {int.lastSync}</span>
                      </>
                    )}
                  </div>
                </div>
              </div>
              <button className="bg-slate-50 text-slate-600 px-4 py-2 rounded-xl text-xs font-bold hover:bg-slate-100 transition-colors">
                Konfigurálás
              </button>
            </div>
          ))}
        </div>
      </div>

      {/* API Key Instructions */}
      <div className="bg-slate-900 rounded-3xl p-8 text-white">
        <div className="flex items-start gap-6">
          <div className="w-12 h-12 bg-white/10 rounded-2xl flex items-center justify-center text-indigo-400">
            <ICONS.Key size={24} />
          </div>
          <div className="flex-1">
            <h4 className="text-lg font-bold mb-2">Élesítés (Production) Útmutató</h4>
            <p className="text-slate-400 text-sm leading-relaxed mb-6">
              Az alkalmazás élesítésekor a `.env` fájlban kell megadni a megfelelő API kulcsokat. 
              A rendszer automatikusan felismeri a kitöltött változókat és átvált "Live" módba.
            </p>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="bg-white/5 p-4 rounded-xl border border-white/10">
                <p className="text-[10px] font-bold text-indigo-400 uppercase mb-1">Stripe Integration</p>
                <code className="text-xs text-slate-300">VITE_STRIPE_PUBLIC_KEY=pk_live_...</code>
              </div>
              <div className="bg-white/5 p-4 rounded-xl border border-white/10">
                <p className="text-[10px] font-bold text-indigo-400 uppercase mb-1">Billingo API</p>
                <code className="text-xs text-slate-300">BILLINGO_API_KEY=bg_...</code>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );

  const renderPaymentPortal = () => {
    const pendingStudents = students?.filter(s => s.status === 'Accepted' && s.paymentLink) || [];

    return (
      <div className="max-w-4xl mx-auto space-y-8 animate-in zoom-in-95 duration-500">
        <div className="bg-indigo-900 rounded-3xl p-8 text-white shadow-2xl relative overflow-hidden">
          <div className="absolute top-0 right-0 p-8 opacity-10">
            <ICONS.CreditCard size={120} />
          </div>
          <div className="relative z-10">
            <h3 className="text-2xl font-bold mb-2">Fizetési Portál (Teszt Üzemmód)</h3>
            <p className="text-indigo-200 text-sm max-w-lg">
              Ez a felület szimulálja azt az oldalt, amit a jelentkező lát a Feltételes Felvételi levél kiküldése után. 
              Választható bankkártyás fizetés vagy banki átutalás bizonylat feltöltéssel.
            </p>
          </div>
        </div>

        {pendingStudents.length === 0 ? (
          <div className="bg-white p-12 rounded-3xl border border-slate-100 shadow-sm text-center">
            <div className="w-16 h-16 bg-slate-50 text-slate-300 rounded-full flex items-center justify-center mx-auto mb-4">
              <ICONS.CheckCircle size={32} />
            </div>
            <h4 className="font-bold text-slate-800 text-lg">Nincs függőben lévő fizetés</h4>
            <p className="text-slate-400 text-sm mt-1">Minden kiküldött ajánlat kifizetésre került vagy még nem küldtek ajánlatot.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 gap-6">
            {pendingStudents.map(student => {
              const method = paymentMethod[student.id] || 'card';
              
              return (
                <div key={student.id} className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm space-y-8">
                  <div className="flex flex-col md:flex-row items-center justify-between gap-8">
                    <div className="flex items-center gap-6">
                      <div className="w-16 h-16 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center font-bold text-xl">
                        {student.name.charAt(0)}
                      </div>
                      <div>
                        <h4 className="font-bold text-slate-800 text-xl">{student.name}</h4>
                        <p className="text-sm text-slate-400">{student.program}</p>
                        <div className="flex items-center gap-2 mt-2">
                          <span className="px-2 py-1 bg-amber-50 text-amber-600 rounded text-[10px] font-bold uppercase">Fizetésre vár</span>
                          <span className="text-[10px] text-slate-400 font-bold uppercase">Összeg: €{student.tuitionFee.toLocaleString()}</span>
                        </div>
                      </div>
                    </div>

                    <div className="flex bg-slate-50 p-1 rounded-xl border border-slate-100">
                      <button 
                        onClick={() => setPaymentMethod({...paymentMethod, [student.id]: 'card'})}
                        className={`px-4 py-2 rounded-lg text-xs font-bold transition-all ${method === 'card' ? 'bg-white text-indigo-600 shadow-sm' : 'text-slate-400'}`}
                      >
                        Bankkártya
                      </button>
                      <button 
                        onClick={() => setPaymentMethod({...paymentMethod, [student.id]: 'transfer'})}
                        className={`px-4 py-2 rounded-lg text-xs font-bold transition-all ${method === 'transfer' ? 'bg-white text-indigo-600 shadow-sm' : 'text-slate-400'}`}
                      >
                        Átutalás
                      </button>
                    </div>
                  </div>

                  <div className="pt-8 border-t border-slate-50">
                    {method === 'card' ? (
                      <div className="flex flex-col items-center gap-4">
                        <button 
                          onClick={() => handleSimulatePayment(student.id, student.tuitionFee)}
                          disabled={isProcessing === student.id}
                          className="w-full md:w-auto bg-indigo-600 text-white px-12 py-4 rounded-2xl font-bold shadow-xl shadow-indigo-100 hover:bg-indigo-700 transition-all flex items-center justify-center gap-2"
                        >
                          {isProcessing === student.id ? (
                            <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                          ) : (
                            <>
                              <ICONS.CreditCard size={20} />
                              Bankkártyás Fizetés Indítása
                            </>
                          )}
                        </button>
                        <p className="text-[10px] text-slate-400 italic">Biztonságos fizetés a Stripe rendszerén keresztül</p>
                      </div>
                    ) : (
                      <div className="space-y-6">
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                          <div className="bg-slate-50 p-6 rounded-2xl border border-slate-100">
                            <h5 className="text-xs font-bold text-slate-400 uppercase mb-4 tracking-widest">Utalási Adatok</h5>
                            <div className="space-y-2 text-sm">
                              <p className="flex justify-between"><span className="text-slate-400">Kedvezményezett:</span> <span className="font-bold text-slate-800">University of Pro</span></p>
                              <p className="flex justify-between"><span className="text-slate-400">IBAN:</span> <span className="font-bold text-slate-800">HU12 3456 7890 1234 5678</span></p>
                              <p className="flex justify-between"><span className="text-slate-400">SWIFT/BIC:</span> <span className="font-bold text-slate-800">UNIPROHU2X</span></p>
                              <p className="flex justify-between"><span className="text-slate-400">Közlemény:</span> <span className="font-bold text-indigo-600">{student.id} - {student.name}</span></p>
                            </div>
                          </div>
                          <div className="flex flex-col justify-center items-center border-2 border-dashed border-slate-200 rounded-2xl p-6 hover:border-indigo-400 hover:bg-indigo-50/30 transition-all cursor-pointer group" onClick={() => handleUploadProof(student.id, student.tuitionFee)}>
                            {uploadingFile === student.id ? (
                              <div className="flex flex-col items-center">
                                <div className="w-8 h-8 border-3 border-indigo-600 border-t-transparent rounded-full animate-spin mb-2"></div>
                                <span className="text-xs font-bold text-indigo-600">Feltöltés...</span>
                              </div>
                            ) : (
                              <>
                                <ICONS.Upload size={32} className="text-slate-300 group-hover:text-indigo-500 mb-2 transition-colors" />
                                <span className="text-xs font-bold text-slate-500 group-hover:text-indigo-600">Utalási bizonylat feltöltése</span>
                                <span className="text-[10px] text-slate-400 mt-1">PDF, JPG vagy PNG (max. 5MB)</span>
                              </>
                            )}
                          </div>
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        <div className="bg-slate-50 p-6 rounded-3xl border border-slate-100">
          <div className="flex items-start gap-4">
            <div className="w-10 h-10 bg-white rounded-xl flex items-center justify-center text-amber-500 shadow-sm border border-slate-100">
              <ICONS.AlertCircle size={20} />
            </div>
            <div>
              <h5 className="font-bold text-slate-800 text-sm">Integrációs Megjegyzés</h5>
              <p className="text-xs text-slate-500 mt-1 leading-relaxed">
                A fizetés után a rendszer automatikusan "Paid" státuszba helyezi a diákot, és rögzíti a tranzakciót a Pénzügyek listában. 
                Éles üzemben itt történik az átirányítás a banki felületre.
              </p>
            </div>
          </div>
        </div>
      </div>
    );
  };

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Module Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Pénzügyek</h2>
          <p className="text-slate-500 mt-1">Bevételek, jelentkezési díjak és tandíj előlegek központi kezelése.</p>
        </div>
        <div className="flex items-center gap-3">
          <button 
            onClick={() => setShowRecordModal(true)}
            className="flex items-center gap-2 bg-slate-900 text-white px-6 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-slate-200 hover:bg-black transition-all"
          >
            <ICONS.Receipt size={18} /> Új kifizetés rögzítése
          </button>
        </div>
      </div>

      {/* Record Payment Modal */}
      {showRecordModal && (
        <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-sm z-[100] flex items-center justify-center p-6 animate-in fade-in duration-300">
          <div className="bg-white w-full max-w-lg rounded-[32px] shadow-2xl overflow-hidden animate-in zoom-in-95 duration-300">
            <div className="p-8 border-b border-slate-50 flex justify-between items-center bg-slate-50/50">
              <div>
                <h3 className="text-xl font-black text-slate-900 tracking-tight">Kifizetés Rögzítése</h3>
                <p className="text-xs text-slate-500 font-medium mt-1">Manuális tranzakció rögzítése a rendszerben</p>
              </div>
              <button 
                onClick={() => setShowRecordModal(false)}
                className="w-10 h-10 flex items-center justify-center rounded-xl hover:bg-white transition-all text-slate-400 hover:text-slate-600"
              >
                <ICONS.X size={20} />
              </button>
            </div>
            
            <form onSubmit={handleRecordPayment} className="p-8 space-y-6">
              <div className="grid grid-cols-1 gap-6">
                <div>
                  <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Hallgató Neve</label>
                  <select 
                    value={newPayment.studentName}
                    onChange={(e) => setNewPayment({...newPayment, studentName: e.target.value})}
                    className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                    required
                  >
                    <option value="">Válasszon hallgatót...</option>
                    {students?.map(s => (
                      <option key={s.id} value={s.name}>{s.name} ({s.program})</option>
                    ))}
                  </select>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Típus</label>
                    <select 
                      value={newPayment.type}
                      onChange={(e) => setNewPayment({...newPayment, type: e.target.value as any})}
                      className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                    >
                      <option value="Tuition">Tandíj</option>
                      <option value="Application Fee">Jelentkezési díj</option>
                      <option value="Deposit">Előleg</option>
                    </select>
                  </div>
                  <div>
                    <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Fizetési Mód</label>
                    <select 
                      value={newPayment.method}
                      onChange={(e) => setNewPayment({...newPayment, method: e.target.value as any})}
                      className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                    >
                      <option value="Bank Transfer">Banki Átutalás</option>
                      <option value="Stripe">Stripe (Kártya)</option>
                      <option value="PayPal">PayPal</option>
                      <option value="Cash">Készpénz</option>
                    </select>
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Összeg</label>
                    <input 
                      type="number"
                      value={newPayment.amount}
                      onChange={(e) => setNewPayment({...newPayment, amount: Number(e.target.value)})}
                      className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all font-bold"
                      required
                    />
                  </div>
                  <div>
                    <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Deviza</label>
                    <select 
                      value={newPayment.currency}
                      onChange={(e) => setNewPayment({...newPayment, currency: e.target.value as any})}
                      className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                    >
                      <option value="EUR">EUR</option>
                      <option value="USD">USD</option>
                      <option value="HUF">HUF</option>
                    </select>
                  </div>
                </div>
              </div>

              <div className="pt-4 flex gap-4">
                <button 
                  type="button"
                  onClick={() => setShowRecordModal(false)}
                  className="flex-1 py-4 rounded-2xl font-bold text-slate-500 hover:bg-slate-50 transition-all"
                >
                  Mégse
                </button>
                <button 
                  type="submit"
                  className="flex-1 bg-primary text-white py-4 rounded-2xl font-bold shadow-xl shadow-primary/10 hover:bg-primary/90 transition-all active:scale-95"
                >
                  Rögzítés
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {renderStats()}

      {/* Local Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('payments')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'payments' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Befizetések (App Fees)
        </button>
        <button 
          onClick={() => setActiveSubView('deposits')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'deposits' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Tandíj Előlegek (Deposit)
        </button>
        <button 
          onClick={() => setActiveSubView('currencies')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'currencies' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Deviza Kezelés
        </button>
        <button 
          onClick={() => setActiveSubView('scholarships')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'scholarships' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Ösztöndíjak
        </button>
        <button 
          onClick={() => setActiveSubView('integrations')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'integrations' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Integrációk
        </button>
        <button 
          onClick={() => setActiveSubView('payment_portal')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'payment_portal' ? 'bg-indigo-600 text-white shadow-md' : 'text-indigo-500 hover:text-indigo-800'}`}
        >
          <span className="flex items-center gap-2">
            <ICONS.CreditCard size={14} /> Fizetési Portál (Test)
          </span>
        </button>
      </div>

      {/* Dynamic Content */}
      <div className="mt-8">
        {activeSubView === 'payments' && renderPayments()}
        {activeSubView === 'deposits' && renderDeposits()}
        {activeSubView === 'currencies' && renderCurrencies()}
        {activeSubView === 'scholarships' && renderScholarships()}
        {activeSubView === 'integrations' && renderIntegrations()}
        {activeSubView === 'payment_portal' && renderPaymentPortal()}
      </div>
    </div>
  );
};
return Finance;
})();

/* ===== ImmigrationCompliance ===== */
const ImmigrationCompliance = (() => {
type ImmigrationSubView = 'checklist' | 'interview' | 'risk';

const mockRiskFactors: RiskFactor[] = [
  { label: 'Tanulmányi hézag (Study Gap)', impact: 'High', description: 'A diák 4 évet hagyott ki a középiskola és az egyetem között magyarázat nélkül.' },
  { label: 'Származási ország statisztika', impact: 'Medium', description: 'Nigériai jelentkezők elutasítási aránya az elmúlt 12 hónapban: 18%.' },
  { label: 'Pénzügyi háttér', impact: 'Low', description: 'A szponzori igazolás megfelelő, stabil jövedelem látható.' },
];

const ImmigrationCompliance: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<ImmigrationSubView>('checklist');
  const { data: students, isLoading: studentsLoading, refresh: refreshStudents } = useApi(api.getStudents);
  const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
  const [isUpdating, setIsUpdating] = useState(false);

  const selectedStudent = students?.find(s => s.id === selectedStudentId);

  useEffect(() => {
    if (students && students.length > 0 && !selectedStudentId) {
      setSelectedStudentId(students[0].id);
    }
  }, [students, selectedStudentId]);

  const handleUpdateItemStatus = async (itemId: string, newStatus: VisaItem['status']) => {
    if (!selectedStudent || !selectedStudent.visaChecklist) return;

    setIsUpdating(true);
    try {
      const updatedChecklist = selectedStudent.visaChecklist.map(item => 
        item.id === itemId ? { ...item, status: newStatus } : item
      );
      await api.updateStudent(selectedStudent.id, { visaChecklist: updatedChecklist });
      refreshStudents();
    } catch (error) {
      console.error('Failed to update checklist item:', error);
    } finally {
      setIsUpdating(false);
    }
  };

  const handleUpdateVisaStatus = async (newStatus: Student['visaApplication']['status']) => {
    if (!selectedStudent || !selectedStudent.visaApplication) return;

    setIsUpdating(true);
    try {
      const updatedApplication = { ...selectedStudent.visaApplication, status: newStatus };
      await api.updateStudent(selectedStudent.id, { visaApplication: updatedApplication });
      refreshStudents();
    } catch (error) {
      console.error('Failed to update visa status:', error);
    } finally {
      setIsUpdating(false);
    }
  };

  const renderStudentSidebar = () => (
    <div className="w-80 bg-white border-r border-slate-100 h-[calc(100vh-120px)] overflow-y-auto">
      <div className="p-6 border-b border-slate-50">
        <div className="relative">
          <ICONS.Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={16} />
          <input 
            type="text" 
            placeholder="Jelentkező keresése..." 
            className="w-full pl-10 pr-4 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
          />
        </div>
      </div>
      <div className="divide-y divide-slate-50">
        {studentsLoading ? (
          <div className="p-8 text-center text-slate-400 text-xs">Betöltés...</div>
        ) : (
          students?.map(student => (
            <button
              key={student.id}
              onClick={() => setSelectedStudentId(student.id)}
              className={`w-full p-4 text-left hover:bg-slate-50 transition-colors flex items-center gap-3 ${selectedStudentId === student.id ? 'bg-indigo-50/50 border-r-2 border-indigo-600' : ''}`}
            >
              <div className="w-10 h-10 bg-slate-100 rounded-xl flex items-center justify-center text-slate-500 font-bold">
                {student.name.charAt(0)}
              </div>
              <div className="min-w-0">
                <p className="font-bold text-slate-800 text-sm truncate">{student.name}</p>
                <p className="text-[10px] text-slate-400 truncate">{student.program}</p>
                <div className="flex items-center gap-2 mt-1">
                  <span className={`w-1.5 h-1.5 rounded-full ${
                    student.status === 'Paid' ? 'bg-emerald-500' : 
                    student.status === 'Accepted' ? 'bg-indigo-500' : 'bg-amber-500'
                  }`} />
                  <span className="text-[10px] font-bold text-slate-400 uppercase">{student.status}</span>
                </div>
              </div>
            </button>
          ))
        )}
      </div>
    </div>
  );

  const renderChecklist = () => {
    if (!selectedStudent) return null;

    const checklist = selectedStudent.visaChecklist || [];

    return (
      <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
        {selectedStudent.visaApplication && (
          <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
            <div className="flex justify-between items-start mb-6">
              <div>
                <h4 className="text-sm font-bold text-slate-400 uppercase tracking-widest mb-1">Vízum Kérelem Állapota</h4>
                <div className="flex items-center gap-3">
                  <span className={`px-4 py-1.5 rounded-xl text-xs font-bold uppercase tracking-widest ${
                    selectedStudent.visaApplication.status === 'Approved' ? 'bg-emerald-100 text-emerald-700' :
                    selectedStudent.visaApplication.status === 'Rejected' ? 'bg-red-100 text-red-700' :
                    selectedStudent.visaApplication.status === 'In Progress' ? 'bg-blue-100 text-blue-700' : 'bg-slate-100 text-slate-600'
                  }`}>
                    {selectedStudent.visaApplication.status}
                  </span>
                  <p className="text-sm text-slate-500 font-medium">Típus: {selectedStudent.visaApplication.type}</p>
                </div>
              </div>
              <div className="flex gap-2">
                <select 
                  className="bg-slate-50 border border-slate-200 rounded-xl px-4 py-2 text-xs font-bold focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                  value={selectedStudent.visaApplication.status}
                  onChange={(e) => handleUpdateVisaStatus(e.target.value as any)}
                  disabled={isUpdating}
                >
                  <option value="Not Started">Nincs elkezdve</option>
                  <option value="In Progress">Folyamatban</option>
                  <option value="Submitted">Beadva</option>
                  <option value="Interview Scheduled">Interjú kitűzve</option>
                  <option value="Approved">Elfogadva</option>
                  <option value="Rejected">Elutasítva</option>
                </select>
              </div>
            </div>
            
            <div className="grid grid-cols-2 md:grid-cols-4 gap-6 pt-6 border-t border-slate-50">
              <div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-1">Beadás dátuma</p>
                <p className="text-sm font-bold text-slate-800">{selectedStudent.visaApplication.submissionDate || '---'}</p>
              </div>
              <div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-1">Konzulátus</p>
                <p className="text-sm font-bold text-slate-800">{selectedStudent.visaApplication.consulate || '---'}</p>
              </div>
              <div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-1">Vízum szám</p>
                <p className="text-sm font-bold text-slate-800">{selectedStudent.visaApplication.visaNumber || '---'}</p>
              </div>
              <div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-1">Lejárat</p>
                <p className="text-sm font-bold text-slate-800">{selectedStudent.visaApplication.expiryDate || '---'}</p>
              </div>
            </div>
          </div>
        )}

        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-8">
            <div>
              <h3 className="text-xl font-bold text-slate-800">Vízum Dokumentumok Bírálata</h3>
              <p className="text-sm text-slate-400 mt-1">
                Jelentkező: <span className="text-slate-800 font-bold">{selectedStudent.name}</span> ({selectedStudent.country || 'Nincs megadva'})
              </p>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-xs font-bold text-slate-400 uppercase tracking-widest">Ország:</span>
              <div className="bg-slate-50 border border-slate-200 px-4 py-2 rounded-xl text-sm font-semibold">
                {selectedStudent.country || 'N/A'}
              </div>
            </div>
          </div>

          {checklist.length === 0 ? (
            <div className="p-12 text-center border-2 border-dashed border-slate-100 rounded-3xl">
              <ICONS.FileText size={48} className="mx-auto text-slate-200 mb-4" />
              <p className="text-slate-400 text-sm">Ehhez a jelentkezőhöz még nincs generálva checklist.</p>
              <button className="mt-4 bg-indigo-600 text-white px-6 py-2 rounded-xl text-xs font-bold">Checklist Generálása</button>
            </div>
          ) : (
            <div className="space-y-4">
              {checklist.map((item) => (
                <div key={item.id} className="group flex items-center justify-between p-4 bg-slate-50/50 rounded-2xl border border-transparent hover:border-slate-200 hover:bg-white transition-all">
                  <div className="flex items-center gap-4">
                    <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${
                      item.status === 'Verified' ? 'bg-emerald-50 text-emerald-600' :
                      item.status === 'Rejected' ? 'bg-red-50 text-red-600' :
                      item.status === 'Uploaded' ? 'bg-indigo-50 text-indigo-600' : 'bg-slate-200 text-slate-400'
                    }`}>
                      <ICONS.FileText size={20} />
                    </div>
                    <div>
                      <div className="flex items-center gap-2">
                        <p className="font-bold text-slate-800 text-sm">{item.label}</p>
                        {item.required && <span className="text-[10px] bg-red-50 text-red-500 px-1.5 py-0.5 rounded font-bold">KÖTELEZŐ</span>}
                      </div>
                      <p className="text-[10px] text-slate-400 font-bold uppercase tracking-tight mt-0.5">Státusz: {item.status}</p>
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    {item.status === 'Uploaded' && (
                      <div className="flex items-center gap-2">
                        <button 
                          onClick={() => handleUpdateItemStatus(item.id, 'Verified')}
                          disabled={isUpdating}
                          className="bg-emerald-600 text-white px-3 py-1.5 rounded-lg text-[10px] font-bold hover:bg-emerald-700 transition-colors"
                        >
                          Elfogadás
                        </button>
                        <button 
                          onClick={() => handleUpdateItemStatus(item.id, 'Rejected')}
                          disabled={isUpdating}
                          className="bg-red-600 text-white px-3 py-1.5 rounded-lg text-[10px] font-bold hover:bg-red-700 transition-colors"
                        >
                          Elutasítás
                        </button>
                      </div>
                    )}
                    {item.status === 'Rejected' && (
                      <button className="text-[10px] font-bold text-indigo-600 hover:underline">Újrafeltöltés kérése</button>
                    )}
                    <button className="p-2 text-slate-400 hover:text-indigo-600 bg-white border border-slate-100 rounded-lg shadow-sm opacity-0 group-hover:opacity-100 transition-opacity">
                      <ICONS.Eye size={16} />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  };

  const renderInterviewPrep = () => (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="space-y-6">
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm h-full">
          <div className="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center mb-6">
            <ICONS.Mic size={24} />
          </div>
          <h3 className="text-xl font-bold text-slate-800 mb-2">Vízum Interjú Felkészítő</h3>
          <p className="text-sm text-slate-500 leading-relaxed mb-8">
            Ez a modul segít a diákoknak felkészülni a nagykövetségi interjúra. A rendszer rögzíti a válaszokat, és AI vagy mentor segítségével pontozza azokat.
          </p>
          
          <div className="space-y-4">
            <h4 className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-4">Gyakori Kérdések</h4>
            {[
              'Miért pont ezt az egyetemet választotta?',
              'Hogyan fogja finanszírozni a tanulmányait?',
              'Mik a tervei a diploma megszerzése után?',
              'Vannak-e rokonai az országban?'
            ].map((q, i) => (
              <div key={i} className="p-4 bg-slate-50 rounded-2xl border border-slate-100 flex items-center justify-between group cursor-pointer hover:bg-white hover:shadow-md transition-all">
                <p className="text-sm font-semibold text-slate-700">{q}</p>
                <button className="w-8 h-8 bg-indigo-600 text-white rounded-lg flex items-center justify-center shadow-lg shadow-indigo-100 scale-0 group-hover:scale-100 transition-transform">
                  <ICONS.ChevronRight size={16} />
                </button>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="space-y-6">
        <div className="bg-slate-900 rounded-3xl p-8 text-white relative overflow-hidden h-full">
          <div className="absolute top-0 right-0 p-12 opacity-10">
            <ICONS.Video size={120} />
          </div>
          <div className="relative z-10 flex flex-col h-full">
            <div className="mb-auto">
              <div className="flex items-center gap-2 mb-6">
                <div className="w-2 h-2 bg-red-500 rounded-full animate-pulse" />
                <span className="text-[10px] font-bold uppercase tracking-widest">Gyakorló Mód Aktív</span>
              </div>
              <h4 className="text-2xl font-bold mb-4">"Miért pont ezt a szakot választotta?"</h4>
              <p className="text-slate-400 text-sm italic mb-8">Válasz rögzítése a visszajelzéshez...</p>
            </div>
            
            <div className="bg-white/5 rounded-2xl p-6 border border-white/10 mb-8">
              <p className="text-xs text-slate-300 font-medium">Mentori Tipp:</p>
              <p className="text-sm text-slate-200 mt-2 leading-relaxed">
                "A válaszában ne csak a szak nevét említse, hanem kapcsolja össze a korábbi tanulmányaival és a jövőbeli karriercéljaival."
              </p>
            </div>

            <button className="w-full bg-white text-slate-900 py-4 rounded-2xl font-bold flex items-center justify-center gap-2 hover:bg-slate-100 transition-all shadow-xl">
              <ICONS.Mic size={20} /> Válasz rögzítése
            </button>
          </div>
        </div>
      </div>
    </div>
  );

  const renderRiskAnalysis = () => {
    if (!selectedStudent) return null;
    
    const riskFactors = selectedStudent.visaApplication?.riskFactors || mockRiskFactors;
    const riskScore = riskFactors.length > 0 ? (riskFactors.some(f => f.impact === 'High') ? 85 : 45) : 10;
    const riskLabel = riskScore > 70 ? 'High Risk' : riskScore > 30 ? 'Medium Risk' : 'Low Risk';
    const riskColor = riskScore > 70 ? 'text-red-500' : riskScore > 30 ? 'text-amber-500' : 'text-emerald-500';
    const strokeColor = riskScore > 70 ? 'text-red-500' : riskScore > 30 ? 'text-amber-500' : 'text-emerald-500';

    return (
      <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-1 bg-white p-8 rounded-3xl border border-slate-100 shadow-sm flex flex-col items-center text-center">
            <h3 className="font-bold text-slate-800 text-lg mb-8 uppercase tracking-widest text-[10px] text-slate-400">Risk Scoring</h3>
            <div className="relative w-48 h-48 flex items-center justify-center mb-8">
               {/* Simple SVG Gauge */}
               <svg className="w-full h-full transform -rotate-90">
                 <circle cx="96" cy="96" r="80" stroke="currentColor" strokeWidth="12" fill="transparent" className="text-slate-100" />
                 <circle cx="96" cy="96" r="80" stroke="currentColor" strokeWidth="12" fill="transparent" strokeDasharray="502.6" strokeDashoffset={502.6 - (502.6 * riskScore / 100)} className={strokeColor} />
               </svg>
               <div className="absolute flex flex-col items-center">
                 <span className={`text-5xl font-black ${riskColor}`}>{riskScore}</span>
                 <span className="text-[10px] font-bold text-slate-400 uppercase tracking-tighter">{riskLabel}</span>
               </div>
            </div>
            <p className="text-sm text-slate-500 leading-relaxed">
              {riskScore > 70 ? 'A vízumelutasítási kockázat magas. Szigorú ellenőrzés és kiegészítő dokumentáció szükséges.' : 
               riskScore > 30 ? 'A vízumelutasítási kockázat közepes. További dokumentáció javasolt a tanulmányi hézag igazolására.' :
               'A vízumelutasítási kockázat alacsony. A jelentkező profilja megfelel a követelményeknek.'}
            </p>
          </div>

          <div className="lg:col-span-2 space-y-6">
            <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
              <h4 className="font-bold text-slate-800 mb-6">Kockázati Tényezők (Risk Factors)</h4>
              <div className="space-y-4">
                {riskFactors.map((factor, i) => (
                  <div key={i} className="p-6 bg-slate-50 rounded-2xl border border-slate-100 flex gap-6">
                    <div className={`mt-1 flex-shrink-0 w-3 h-3 rounded-full ${
                      factor.impact === 'High' ? 'bg-red-500 shadow-[0_0_10px_rgba(239,68,68,0.5)]' :
                      factor.impact === 'Medium' ? 'bg-amber-500 shadow-[0_0_10px_rgba(245,158,11,0.5)]' : 'bg-emerald-500 shadow-[0_0_10px_rgba(16,185,129,0.5)]'
                    }`} />
                    <div>
                      <div className="flex items-center gap-3 mb-1">
                        <h5 className="font-bold text-slate-800 text-sm">{factor.label}</h5>
                        <span className={`text-[10px] font-bold px-2 py-0.5 rounded uppercase ${
                          factor.impact === 'High' ? 'bg-red-50 text-red-600' :
                          factor.impact === 'Medium' ? 'bg-amber-50 text-amber-600' : 'bg-emerald-50 text-emerald-600'
                        }`}>
                          {factor.impact} Impact
                        </span>
                      </div>
                      <p className="text-xs text-slate-500 leading-relaxed">{factor.description}</p>
                    </div>
                  </div>
                ))}
              </div>
            </div>

          <div className="bg-indigo-50 p-6 rounded-2xl border border-indigo-100 flex items-center justify-between">
            <div className="flex items-center gap-4">
               <div className="w-10 h-10 bg-indigo-600 text-white rounded-xl flex items-center justify-center">
                 <ICONS.Zap size={20} />
               </div>
               <div>
                 <p className="text-sm font-bold text-indigo-900">Compliance Javaslat</p>
                 <p className="text-xs text-indigo-700">Kérjen a diáktól egy részletes önéletrajzot és motivációs levelet a kérelem mellé.</p>
               </div>
            </div>
            <button className="text-[10px] font-bold text-indigo-600 uppercase tracking-widest hover:underline">Részletek</button>
          </div>
        </div>
      </div>
    </div>
  );
};

  return (
    <div className="flex h-[calc(100vh-64px)] overflow-hidden">
      {renderStudentSidebar()}
      
      <div className="flex-1 overflow-y-auto bg-slate-50/30">
        <div className="max-w-5xl mx-auto p-8 space-y-8">
          {/* Module Header */}
          <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
            <div>
              <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Vízum és Compliance</h2>
              <p className="text-slate-500 mt-1">Nemzetközi jelentkezők vízumügyintézésének támogatása és bírálata.</p>
            </div>
            <div className="flex items-center gap-3">
              <button className="flex items-center gap-2 bg-slate-900 text-white px-6 py-2.5 rounded-xl text-sm font-bold shadow-lg shadow-slate-200 hover:bg-black transition-all">
                <ICONS.Flag size={18} /> Ország-profilok
              </button>
            </div>
          </div>

          {/* Local Tabs */}
          <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
            <button 
              onClick={() => setActiveSubView('checklist')}
              className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'checklist' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
            >
              Vízum Checklist
            </button>
            <button 
              onClick={() => setActiveSubView('interview')}
              className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'interview' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
            >
              Interjú Felkészítő
            </button>
            <button 
              onClick={() => setActiveSubView('risk')}
              className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'risk' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
            >
              Kockázatelemzés (Risk)
            </button>
          </div>

          {/* Dynamic Content */}
          <div className="mt-8">
            {activeSubView === 'checklist' && renderChecklist()}
            {activeSubView === 'interview' && renderInterviewPrep()}
            {activeSubView === 'risk' && renderRiskAnalysis()}
          </div>
        </div>
      </div>
    </div>
  );
};
return ImmigrationCompliance;
})();

/* ===== Evaluation ===== */
const Evaluation = (() => {
type EvaluationSubView = 'scorecard' | 'committee' | 'video' | 'recommendations';

const mockCriteria: Criterion[] = [
  { id: '1', label: 'Szakmai Motiváció', maxScore: 5, currentScore: 4 },
  { id: '2', label: 'Tanulmányi Átlag (GPA)', maxScore: 10, currentScore: 8 },
  { id: '3', label: 'Nyelvi Készségek', maxScore: 5, currentScore: 3 },
  { id: '4', label: 'Szakmai Tapasztalat', maxScore: 5, currentScore: 5 },
  { id: '5', label: 'Ajánlólevelek Minősége', maxScore: 5, currentScore: 4 },
];

const mockComments: EvaluationComment[] = [
  { id: 'C1', author: 'Dr. Szabó Péter', text: 'A motivációs levél kiemelkedő, látszik a kutatási irányultság.', timestamp: '10:20' },
  { id: 'C2', author: 'Kovács Anita', text: 'A matematikai alapok erősek, de a programozási tapasztalat kevés.', timestamp: '11:45' },
  { id: 'C3', author: 'Dr. Szabó Péter', text: 'Egyetértek, de a szakmai gyakorlata ezt kompenzálhatja.', timestamp: '11:50' },
];

const mockVideos: VideoInterview[] = [
  { id: 'V1', question: 'Miért választotta ezt a szakot?', videoUrl: '#', duration: '01:45' },
  { id: 'V2', question: 'Hol látja magát 5 év múlva a diploma megszerzése után?', videoUrl: '#', duration: '02:10' },
  { id: 'V3', question: 'Meséljen egy szakmai kihívásról, amit sikeresen megoldott!', videoUrl: '#', duration: '03:00' },
];

const Evaluation: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<EvaluationSubView>('scorecard');
  const [scores, setScores] = useState<Criterion[]>(mockCriteria);
  const [selectedVideo, setSelectedVideo] = useState<VideoInterview>(mockVideos[0]);
  const { data: students, isLoading: studentsLoading, refresh: refreshStudents } = useApi(api.getStudents);
  const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (students && students.length > 0 && !selectedStudentId) {
      setSelectedStudentId(students[0].id);
    }
  }, [students, selectedStudentId]);

  const selectedStudent = students?.find(s => s.id === selectedStudentId);

  useEffect(() => {
    if (selectedStudent?.evaluation?.criteria) {
      setScores(selectedStudent.evaluation.criteria);
    } else {
      setScores(mockCriteria);
    }
    
    if (selectedStudent?.evaluation?.videos && selectedStudent.evaluation.videos.length > 0) {
      setSelectedVideo(selectedStudent.evaluation.videos[0]);
    } else {
      setSelectedVideo(mockVideos[0]);
    }
  }, [selectedStudent]);

  const handleScoreChange = (id: string, value: number) => {
    setScores(prev => prev.map(c => c.id === id ? { ...c, currentScore: value } : c));
  };

  const handleSaveEvaluation = async () => {
    if (!selectedStudentId) return;
    setSaving(true);
    try {
      await api.updateStudent(selectedStudentId, {
        evaluation: {
          criteria: scores,
          comments: selectedStudent?.evaluation?.comments || mockComments,
          videos: selectedStudent?.evaluation?.videos || mockVideos
        }
      });
      refreshStudents();
      alert('Bírálat sikeresen mentve!');
    } catch (error) {
      console.error('Save failed:', error);
    } finally {
      setSaving(false);
    }
  };

  const totalPossible = scores.reduce((acc, c) => acc + c.maxScore, 0);
  const currentTotal = scores.reduce((acc, c) => acc + c.currentScore, 0);
  const percentage = Math.round((currentTotal / totalPossible) * 100);

  const renderScorecard = () => (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="lg:col-span-2 space-y-6">
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <h3 className="text-xl font-bold text-slate-800 mb-6 flex items-center gap-2">
            <ICONS.BarChart2 size={24} className="text-indigo-600" />
            Jelentkező Pontozótáblája
          </h3>
          <div className="space-y-8">
            {scores.map((criterion) => (
              <div key={criterion.id} className="space-y-3">
                <div className="flex justify-between items-center">
                  <label className="text-sm font-bold text-slate-700">{criterion.label}</label>
                  <span className="text-sm font-black text-indigo-600 bg-indigo-50 px-3 py-1 rounded-lg">
                    {criterion.currentScore} / {criterion.maxScore}
                  </span>
                </div>
                <div className="flex gap-2">
                  {Array.from({ length: criterion.maxScore }).map((_, i) => (
                    <button
                      key={i}
                      onClick={() => handleScoreChange(criterion.id, i + 1)}
                      className={`flex-1 h-2 rounded-full transition-all ${
                        i < criterion.currentScore ? 'bg-indigo-500' : 'bg-slate-100 hover:bg-slate-200'
                      }`}
                    />
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="space-y-6">
        <div className="bg-indigo-900 rounded-3xl p-8 text-white shadow-xl shadow-indigo-100">
          <p className="text-indigo-300 text-[10px] font-bold uppercase tracking-widest mb-2">Összesített Értékelés</p>
          <div className="flex items-baseline gap-2 mb-6">
            <h2 className="text-5xl font-black">{percentage}%</h2>
            <span className="text-indigo-300 text-lg">Score</span>
          </div>
          <div className="w-full bg-white/10 h-3 rounded-full overflow-hidden mb-6">
            <div className="bg-emerald-400 h-full transition-all duration-1000" style={{ width: `${percentage}%` }} />
          </div>
          <div className="space-y-4">
            <div className="flex justify-between text-xs border-b border-white/10 pb-2">
              <span className="text-indigo-200">Elért pontszám:</span>
              <span className="font-bold">{currentTotal} pt</span>
            </div>
            <div className="flex justify-between text-xs border-b border-white/10 pb-2">
              <span className="text-indigo-200">Maximum:</span>
              <span className="font-bold">{totalPossible} pt</span>
            </div>
            <div className="flex justify-between text-xs border-b border-white/10 pb-2">
              <span className="text-indigo-200">Bíráló:</span>
              <span className="font-bold">Dr. Kovács István</span>
            </div>
          </div>
          <button 
            onClick={handleSaveEvaluation}
            disabled={saving}
            className="w-full mt-8 bg-emerald-500 text-white py-4 rounded-2xl font-bold shadow-lg shadow-emerald-900/20 hover:bg-emerald-600 transition-all flex items-center justify-center gap-2"
          >
            {saving ? <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin" /> : 'Bírálat Mentése'}
          </button>
        </div>
      </div>
    </div>
  );

  const renderCommitteeView = () => (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-8 h-[calc(100vh-280px)] animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="lg:col-span-2 bg-white rounded-3xl border border-slate-100 shadow-sm flex flex-col overflow-hidden">
        <div className="p-4 border-b border-slate-50 flex items-center justify-between bg-slate-50/50">
          <div className="flex items-center gap-3">
             <div className="flex -space-x-2">
               {[1, 2, 3].map(i => (
                 <div key={i} className="w-8 h-8 rounded-full border-2 border-white bg-indigo-100 flex items-center justify-center text-[10px] font-bold text-indigo-600">
                   {i === 1 ? 'SP' : i === 2 ? 'KA' : 'KI'}
                 </div>
               ))}
               <button className="w-8 h-8 rounded-full border-2 border-white bg-slate-100 flex items-center justify-center text-slate-400 hover:bg-slate-200 transition-colors">
                 <ICONS.UserPlus size={14} />
               </button>
             </div>
             <span className="text-[10px] text-slate-400 font-bold uppercase tracking-widest ml-4 italic">3 bíráló online</span>
          </div>
        </div>
        <div className="flex-1 p-12 overflow-y-auto">
          <div className="max-w-2xl mx-auto space-y-8 font-serif leading-relaxed text-slate-800">
            <h2 className="text-3xl font-bold border-b pb-4 mb-12">Motivációs Levél</h2>
            <p className="relative group">
              Tisztelt Felvételi Bizottság! 
              Ezúton szeretném benyújtani jelentkezésemet a MSc Computer Science szakra. Az elmúlt években szoftverfejlesztőként dolgoztam, ahol mélyebb betekintést nyertem az algoritmusok világába...
              <span className="absolute -right-8 top-0 w-1 h-6 bg-indigo-500 animate-pulse opacity-0 group-hover:opacity-100" />
            </p>
            <p className="bg-indigo-50/50 p-4 rounded-xl border-l-4 border-indigo-500">
              A kutatási célom az elosztott rendszerek optimalizálása, különös tekintettel a felhőalapú architektúrákra. Úgy gondolom, hogy az Önök egyeteme a legmegfelelőbb hely ezen ismeretek elmélyítésére...
            </p>
            <p>
              Tanulmányaim során mindig is vonzott a mesterséges intelligencia, és több saját projektet is indítottam ezen a területen...
            </p>
          </div>
        </div>
      </div>

      <div className="bg-slate-50 rounded-3xl border border-slate-200 flex flex-col overflow-hidden">
        <div className="p-6 border-b border-slate-200 bg-white">
          <h4 className="font-bold text-slate-800 flex items-center gap-2">
            <ICONS.MessageCircle size={18} className="text-indigo-600" />
            Bizottsági Chat & Megjegyzések
          </h4>
        </div>
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {(selectedStudent?.evaluation?.comments || mockComments).map((comment) => (
            <div key={comment.id} className="bg-white p-4 rounded-2xl shadow-sm border border-slate-100">
              <div className="flex justify-between items-start mb-1">
                <p className="text-[10px] font-black text-indigo-600 uppercase">{comment.author}</p>
                <span className="text-[10px] text-slate-400">{comment.timestamp}</span>
              </div>
              <p className="text-xs text-slate-700 leading-relaxed">{comment.text}</p>
            </div>
          ))}
        </div>
        <div className="p-4 bg-white border-t border-slate-200">
          <div className="relative">
            <input 
              type="text" 
              placeholder="Megjegyzés írása..." 
              className="w-full bg-slate-50 border-none rounded-xl py-3 pl-4 pr-12 text-sm focus:ring-2 focus:ring-indigo-500/20" 
            />
            <button className="absolute right-2 top-1/2 -translate-y-1/2 p-2 text-indigo-600 hover:bg-indigo-50 rounded-lg">
              <ICONS.Send size={16} />
            </button>
          </div>
        </div>
      </div>
    </div>
  );

  const renderVideoInterview = () => {
    const videos = selectedStudent?.evaluation?.videos || [];
    
    if (videos.length === 0) {
      return (
        <div className="flex flex-col items-center justify-center py-20 bg-white rounded-3xl border border-slate-100 shadow-sm animate-in fade-in slide-in-from-bottom-4 duration-500">
          <div className="w-20 h-20 bg-slate-50 text-slate-300 rounded-full flex items-center justify-center mb-6">
            <ICONS.VideoOff size={40} />
          </div>
          <h3 className="text-xl font-bold text-slate-800 mb-2">Nincs rögzített interjú</h3>
          <p className="text-slate-500 max-w-md text-center">
            A jelentkező még nem végezte el az automata videó interjút. Amint rögzíti a válaszait, azok itt fognak megjelenni.
          </p>
        </div>
      );
    }

    return (
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="space-y-6">
          <div className="bg-slate-900 rounded-3xl overflow-hidden shadow-2xl aspect-video relative group">
             {/* Mock Video Player */}
             <div className="absolute inset-0 bg-slate-800 flex items-center justify-center">
               <div className="w-20 h-20 bg-white/10 rounded-full flex items-center justify-center text-white backdrop-blur-sm group-hover:scale-110 transition-transform cursor-pointer">
                 <ICONS.Play size={32} />
               </div>
             </div>
             <div className="absolute bottom-0 left-0 right-0 p-8 bg-gradient-to-t from-black/80 to-transparent text-white">
               <p className="text-[10px] font-bold uppercase tracking-widest text-indigo-300 mb-1">Kérdés {videos.indexOf(selectedVideo) + 1} / {videos.length}</p>
               <h4 className="text-lg font-bold">{selectedVideo.question}</h4>
               <div className="flex items-center gap-4 mt-4">
                 <div className="flex-1 h-1 bg-white/20 rounded-full">
                   <div className="h-full bg-indigo-500 w-1/3" />
                 </div>
                 <span className="text-xs font-mono">00:45 / {selectedVideo.duration}</span>
               </div>
             </div>
          </div>

          <div className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm flex items-center justify-between">
            <div className="flex items-center gap-4">
              <div className="w-10 h-10 bg-indigo-50 text-indigo-600 rounded-xl flex items-center justify-center">
                <ICONS.Video size={20} />
              </div>
              <div>
                <p className="text-sm font-bold text-slate-800">Videóminőség</p>
                <p className="text-xs text-slate-400">1080p • Aszinkron rögzítés</p>
              </div>
            </div>
            <button className="text-indigo-600 text-xs font-bold uppercase tracking-widest hover:underline">Letöltés</button>
          </div>
        </div>

        <div className="space-y-4">
          <h4 className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-4">Interjú Kérdések</h4>
          {videos.map((video, i) => (
            <div 
              key={video.id} 
              onClick={() => setSelectedVideo(video)}
              className={`p-6 rounded-2xl border transition-all cursor-pointer group ${
                selectedVideo.id === video.id ? 'bg-indigo-600 border-indigo-600 text-white shadow-xl shadow-indigo-100' : 'bg-white border-slate-100 text-slate-800 hover:border-indigo-300'
              }`}
            >
              <div className="flex items-start justify-between">
                <div className="flex items-start gap-4">
                  <span className={`text-2xl font-black ${selectedVideo.id === video.id ? 'text-indigo-200' : 'text-slate-100'}`}>0{i + 1}</span>
                  <div>
                    <p className={`font-bold text-sm ${selectedVideo.id === video.id ? 'text-white' : 'text-slate-800'}`}>{video.question}</p>
                    <p className={`text-[10px] mt-1 font-bold ${selectedVideo.id === video.id ? 'text-indigo-200' : 'text-slate-400'}`}>IDŐTARTAM: {video.duration}</p>
                  </div>
                </div>
                <div className={`w-8 h-8 rounded-full flex items-center justify-center transition-all ${
                  selectedVideo.id === video.id ? 'bg-white text-indigo-600 scale-100' : 'bg-slate-50 text-slate-300 group-hover:scale-110'
                }`}>
                  <ICONS.Play size={14} fill={selectedVideo.id === video.id ? 'currentColor' : 'none'} />
                </div>
              </div>
            </div>
          ))}
          
          <div className="mt-8 bg-amber-50 p-6 rounded-2xl border border-amber-100 flex items-start gap-4">
            <ICONS.AlertCircle className="text-amber-600 flex-shrink-0" size={20} />
            <div>
              <p className="text-sm font-bold text-amber-900">Bírálói Segédlet</p>
              <p className="text-xs text-amber-700 leading-relaxed mt-1">A videóinterjú során figyeljen a diák kommunikációs készségére és a válaszok strukturáltságára. Ez a pontozótábla "Kommunikáció" szekciójába tartozik.</p>
            </div>
          </div>
        </div>
      </div>
    );
  };

  const renderRecommendations = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <h3 className="text-xl font-bold text-slate-800 mb-6 flex items-center gap-2">
          <ICONS.FileCheck size={24} className="text-indigo-600" />
          Beérkezett Ajánlólevelek
        </h3>
        
        <div className="space-y-6">
          {selectedStudent?.recommendationLetters && selectedStudent.recommendationLetters.length > 0 ? (
            selectedStudent.recommendationLetters.map((letter) => (
              <div key={letter.id} className="p-8 border border-slate-100 rounded-3xl hover:border-indigo-200 transition-all bg-slate-50/30">
                <div className="flex flex-col md:flex-row justify-between gap-6">
                  <div className="flex gap-6">
                    <div className="w-16 h-16 bg-white rounded-2xl shadow-sm border border-slate-100 flex items-center justify-center text-indigo-600 shrink-0">
                      <ICONS.UserCheck size={32} />
                    </div>
                    <div>
                      <h4 className="text-lg font-bold text-slate-800">{letter.referee.name}</h4>
                      <p className="text-sm text-slate-500 font-medium">{letter.referee.position} @ {letter.referee.institution}</p>
                      <div className="flex gap-4 mt-3">
                        <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Kapcsolat: {letter.referee.relationship}</span>
                        <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Beérkezett: {letter.receivedAt}</span>
                      </div>
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className={`px-4 py-1.5 rounded-xl text-[10px] font-bold uppercase tracking-widest ${
                      letter.status === 'Verified' ? 'bg-emerald-100 text-emerald-700' : 'bg-blue-100 text-blue-700'
                    }`}>
                      {letter.status === 'Verified' ? 'Ellenőrizve' : 'Ellenőrzésre vár'}
                    </span>
                    {letter.status !== 'Verified' && (
                      <button className="bg-indigo-600 text-white px-4 py-1.5 rounded-xl text-[10px] font-bold hover:bg-indigo-700 transition-all">
                        Hitelesítés
                      </button>
                    )}
                  </div>
                </div>
                
                <div className="mt-8 p-6 bg-white rounded-2xl border border-slate-100 font-serif text-sm leading-relaxed text-slate-700 italic">
                  "Kiváló hallgatónak tartom {selectedStudent.name}-t, akit a BME-n töltött évei alatt ismertem meg. Szakmai felkészültsége és problémamegoldó képessége messze meghaladja társaiét..."
                </div>
              </div>
            ))
          ) : (
            <div className="text-center py-12 bg-slate-50 rounded-3xl border border-dashed border-slate-200">
              <ICONS.AlertCircle size={48} className="mx-auto text-slate-300 mb-4" />
              <p className="text-slate-500 font-medium">Még nem érkezett ajánlólevél ehhez a jelentkezőhöz.</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Module Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Felvételi Bírálat</h2>
          <p className="text-slate-500 mt-1">Szakmai bírálati felület, pontozás és bizottsági döntéshozatal.</p>
        </div>
      <div className="flex items-center gap-3">
        <div className="px-4 py-2 bg-indigo-50 text-indigo-600 rounded-xl flex items-center gap-3">
          <div className="w-8 h-8 rounded-full bg-indigo-600 text-white flex items-center justify-center font-bold text-xs shadow-md">
            {selectedStudent?.name.charAt(0) || '?'}
          </div>
          <div>
            <p className="text-[10px] font-bold uppercase tracking-tighter opacity-70">Aktuális Jelentkező</p>
            <select 
              value={selectedStudentId || ''} 
              onChange={(e) => setSelectedStudentId(e.target.value)}
              className="bg-transparent border-none p-0 text-xs font-bold italic focus:ring-0 cursor-pointer"
            >
              {students?.map(s => (
                <option key={s.id} value={s.id}>{s.name}</option>
              ))}
            </select>
          </div>
        </div>
      </div>
      </div>

      {/* Local Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('scorecard')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'scorecard' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Pontozótábla (Scorecard)
        </button>
        <button 
          onClick={() => setActiveSubView('committee')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'committee' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Bizottsági Nézet
        </button>
        <button 
          onClick={() => setActiveSubView('video')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'video' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Videóinterjú (Aszinkron)
        </button>
        <button 
          onClick={() => setActiveSubView('recommendations')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'recommendations' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Ajánlólevelek
        </button>
      </div>

      {/* Dynamic Content */}
      <div className="mt-8">
        {activeSubView === 'scorecard' && renderScorecard()}
        {activeSubView === 'committee' && renderCommitteeView()}
        {activeSubView === 'video' && renderVideoInterview()}
        {activeSubView === 'recommendations' && renderRecommendations()}
      </div>
    </div>
  );
};
return Evaluation;
})();

/* ===== SystemAdmin ===== */
const SystemAdmin = (() => {
type AdminSubView = 'audit' | 'rbac' | 'api';

const SystemAdmin: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<AdminSubView>('audit');
  const { data: auditLogs, isLoading: auditLoading } = useApi(api.getAuditLogs);
  const { data: webhooks, isLoading: webhooksLoading } = useApi(api.getWebhooks);

  const renderAuditLogs = () => (
    <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="p-6 border-b border-slate-50 flex justify-between items-center bg-slate-50/50">
        <div>
          <h3 className="font-bold text-slate-800 text-lg">Eseménynapló (Audit Log)</h3>
          <p className="text-xs text-slate-400">Részletes naplózás a GDPR megfelelőség érdekében.</p>
        </div>
        <button className="flex items-center gap-2 bg-white border border-slate-200 px-4 py-2 rounded-xl text-xs font-bold hover:bg-slate-50 transition-colors">
          <ICONS.Download size={14} /> Log Exportálása (JSON)
        </button>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-left">
          <thead className="bg-slate-50/80 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
            <tr>
              <th className="px-6 py-4">Időpont</th>
              <th className="px-6 py-4">Felhasználó</th>
              <th className="px-6 py-4">Művelet</th>
              <th className="px-6 py-4">Érintett Elem</th>
              <th className="px-6 py-4">Változtatások</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-50">
            {auditLogs?.map((log) => (
              <tr key={log.id} className="hover:bg-slate-50 transition-colors">
                <td className="px-6 py-4">
                  <span className="text-xs font-mono text-slate-400">{log.timestamp}</span>
                </td>
                <td className="px-6 py-4">
                  <div className="flex items-center gap-2">
                    <div className="w-6 h-6 rounded-full bg-slate-100 flex items-center justify-center text-[10px] font-bold text-slate-500">
                      {log.user.charAt(0)}
                    </div>
                    <span className="text-xs font-bold text-slate-700">{log.user}</span>
                  </div>
                </td>
                <td className="px-6 py-4">
                  <span className="text-[10px] bg-slate-100 text-slate-600 px-2 py-1 rounded font-bold uppercase">
                    {log.action}
                  </span>
                </td>
                <td className="px-6 py-4">
                  <span className="text-xs text-slate-800">{log.target}</span>
                </td>
                <td className="px-6 py-4">
                  <span className="text-xs italic text-slate-400">{log.changes}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );

  const renderRBAC = () => (
    <div className="grid grid-cols-1 lg:grid-cols-4 gap-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="lg:col-span-1 space-y-4">
        <h4 className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-4">Szerepkörök</h4>
        {['Rendszergazda', 'Pénzügyes', 'Felvételi Bíráló', 'Tanszékvezető'].map((role, i) => (
          <div key={i} className={`p-4 rounded-2xl border cursor-pointer transition-all ${i === 0 ? 'bg-indigo-600 border-indigo-600 text-white shadow-xl shadow-indigo-100' : 'bg-white border-slate-100 text-slate-800 hover:border-indigo-200'}`}>
            <div className="flex items-center justify-between">
              <span className="text-sm font-bold">{role}</span>
              <ICONS.ChevronRight size={14} className={i === 0 ? 'text-white' : 'text-slate-300'} />
            </div>
          </div>
        ))}
        <button className="w-full mt-4 py-3 border-2 border-dashed border-slate-200 text-slate-400 rounded-2xl text-xs font-bold hover:bg-slate-50 transition-colors">
          + Új szerepkör
        </button>
      </div>

      <div className="lg:col-span-3 bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <div className="flex items-center justify-between mb-8">
          <div>
            <h3 className="text-xl font-bold text-slate-800">Jogosultság Mátrix</h3>
            <p className="text-sm text-slate-400 mt-1">Szerkeszthető jogosultságok a kiválasztott szerepkörhöz.</p>
          </div>
          <button className="bg-slate-900 text-white px-6 py-2 rounded-xl text-xs font-bold">Változtatások Mentése</button>
        </div>

        <div className="space-y-6">
          {[
            { cat: 'Pénzügyek', perms: ['Számlák megtekintése', 'Befizetések rögzítése', 'Pénzügyi riportok exportálása'] },
            { cat: 'Diák Adatok', perms: ['Személyes adatok (PII) megtekintése', 'Diák státusz módosítása', 'Dokumentumok bírálata'] },
            { cat: 'Rendszer', perms: ['Audit logok megtekintése', 'API kulcsok kezelése', 'Szerepkörök szerkesztése'] }
          ].map((category, i) => (
            <div key={i} className="space-y-3">
              <h5 className="text-[10px] font-black text-indigo-600 uppercase tracking-widest">{category.cat}</h5>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {category.perms.map((perm, pi) => (
                  <div key={pi} className="flex items-center justify-between p-4 bg-slate-50 rounded-xl border border-slate-100 group hover:bg-white hover:border-indigo-200 transition-all">
                    <span className="text-xs font-medium text-slate-700">{perm}</span>
                    <div className="w-10 h-5 bg-emerald-500 rounded-full relative cursor-pointer">
                      <div className="absolute top-0.5 right-0.5 w-4 h-4 bg-white rounded-full shadow-sm" />
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  const renderAPIWebhooks = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        {/* API Section */}
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-12 h-12 bg-amber-50 text-amber-600 rounded-2xl flex items-center justify-center">
              <ICONS.Key size={24} />
            </div>
            <h3 className="text-xl font-bold text-slate-800">API Hozzáférés</h3>
          </div>
          <p className="text-sm text-slate-500 leading-relaxed mb-8">
            Generáljon API kulcsokat a külső rendszerek (Neptun, ETR, CRM) integrációjához.
          </p>
          <div className="space-y-4">
            <div className="p-4 bg-slate-900 rounded-2xl border border-slate-800 relative group overflow-hidden">
               <div className="absolute top-0 right-0 p-3 opacity-20 group-hover:opacity-100 transition-opacity">
                 <button className="text-white hover:text-indigo-400"><ICONS.Copy size={16} /></button>
               </div>
               <p className="text-[10px] font-bold text-indigo-400 uppercase tracking-widest mb-1">Live API Key</p>
               <p className="text-xs font-mono text-slate-300 break-all">ak_live_51Mjk8L2p9fX3rZ0aK9L1...</p>
            </div>
            <button className="w-full py-4 bg-slate-50 text-slate-600 rounded-2xl text-xs font-bold hover:bg-indigo-50 hover:text-indigo-600 transition-all">
              Új API kulcs generálása
            </button>
          </div>
        </div>

        {/* Webhook Section */}
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-12 h-12 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center">
              <ICONS.Webhook size={24} />
            </div>
            <h3 className="text-xl font-bold text-slate-800">Webhooks</h3>
          </div>
          <div className="space-y-4">
            {webhooks?.map((hook) => (
              <div key={hook.id} className="p-4 bg-slate-50 rounded-2xl border border-slate-100 flex items-center justify-between">
                <div>
                  <div className="flex items-center gap-2 mb-1">
                    <p className="text-sm font-bold text-slate-800">{hook.event}</p>
                    <span className={`text-[9px] px-1.5 py-0.5 rounded font-black ${hook.status === 'Active' ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-200 text-slate-500'}`}>
                      {hook.status}
                    </span>
                  </div>
                  <p className="text-[10px] font-mono text-slate-400 truncate max-w-[200px]">{hook.url}</p>
                </div>
                <div className="flex gap-2">
                   <button className="p-2 text-slate-400 hover:text-indigo-600"><ICONS.Settings size={16} /></button>
                   <button className="p-2 text-slate-400 hover:text-red-500"><ICONS.Trash2 size={16} /></button>
                </div>
              </div>
            ))}
            <button className="w-full py-4 bg-indigo-600 text-white rounded-2xl text-xs font-bold shadow-lg shadow-indigo-100">
              Új Webhook hozzáadása
            </button>
          </div>
        </div>
      </div>

      {/* Teams Integration Section */}
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <div className="flex items-center justify-between mb-8">
          <div className="flex items-center gap-4">
            <div className="w-14 h-14 bg-indigo-50 text-indigo-600 rounded-2xl flex items-center justify-center">
              <ICONS.Video size={28} />
            </div>
            <div>
              <h3 className="text-xl font-bold text-slate-800">Microsoft Teams Integráció</h3>
              <p className="text-sm text-slate-400 mt-1">Kapcsolja össze a rendszert a Microsoft 365 naptárral az automatikus interjú szervezéshez.</p>
            </div>
          </div>
          <button className="flex items-center gap-2 bg-indigo-600 text-white px-6 py-3 rounded-2xl text-sm font-bold hover:bg-indigo-700 transition-all shadow-lg shadow-indigo-100">
            <ICONS.Zap size={18} /> Microsoft Fiók Összekapcsolása
          </button>
        </div>
        
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
            <p className="text-[10px] font-black text-indigo-600 uppercase tracking-widest mb-2">Státusz</p>
            <p className="text-sm font-bold text-slate-400 italic">Nincs csatlakoztatva</p>
          </div>
          <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
            <p className="text-[10px] font-black text-indigo-600 uppercase tracking-widest mb-2">API Engedélyek</p>
            <p className="text-sm font-bold text-slate-400 italic">Calendars.ReadWrite, OnlineMeetings.ReadWrite</p>
          </div>
          <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
            <p className="text-[10px] font-black text-indigo-600 uppercase tracking-widest mb-2">Szinkronizáció</p>
            <p className="text-sm font-bold text-slate-400 italic">Kikapcsolva</p>
          </div>
        </div>
      </div>

      {/* Integration Card */}
      <div className="bg-slate-900 rounded-3xl p-8 text-white flex flex-col md:flex-row items-center gap-8 relative overflow-hidden">
        <div className="absolute bottom-0 right-0 opacity-10 -mb-8 -mr-8">
           <ICONS.Terminal size={180} />
        </div>
        <div className="flex-1 space-y-4 relative z-10">
          <div className="flex items-center gap-2">
            <ICONS.Database className="text-indigo-400" size={24} />
            <h4 className="text-2xl font-bold">Tanulmányi Rendszer Szinkron</h4>
          </div>
          <p className="text-slate-400 leading-relaxed max-w-xl">
            A UniPortal automatikusan szinkronizálja a felvételt nyert diákokat a Neptun vagy ETR rendszerrel. Minden adatváltozás azonnal frissül a központi adatbázisban.
          </p>
          <div className="flex gap-4 pt-4">
            <div className="text-center">
              <p className="text-indigo-400 text-xl font-bold">24/7</p>
              <p className="text-[10px] uppercase text-slate-500 font-bold">Monitoring</p>
            </div>
            <div className="w-px h-10 bg-white/10" />
            <div className="text-center">
              <p className="text-indigo-400 text-xl font-bold">99.9%</p>
              <p className="text-[10px] uppercase text-slate-500 font-bold">Uptime</p>
            </div>
          </div>
        </div>
        <div className="w-full md:w-fit relative z-10">
          <button className="w-full md:w-fit px-8 py-4 bg-white text-slate-900 rounded-2xl font-bold hover:bg-slate-100 transition-all">
            Karbantartási Mód
          </button>
        </div>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Module Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Rendszerkezelés & Backend</h2>
          <p className="text-slate-500 mt-1">Audit logok, jogosultságkezelés és API integrációk központja.</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2 px-3 py-1.5 bg-emerald-50 text-emerald-600 rounded-lg border border-emerald-100">
             <div className="w-2 h-2 bg-emerald-500 rounded-full animate-pulse" />
             <span className="text-[10px] font-bold uppercase tracking-widest">Minden rendszer üzemkész</span>
          </div>
        </div>
      </div>

      {/* Local Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('audit')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'audit' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Eseménynapló (Audit)
        </button>
        <button 
          onClick={() => setActiveSubView('rbac')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'rbac' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Szerepkörök (RBAC)
        </button>
        <button 
          onClick={() => setActiveSubView('api')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'api' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          API & Webhooks
        </button>
      </div>

      {/* Dynamic Content */}
      <div className="mt-8">
        {activeSubView === 'audit' && renderAuditLogs()}
        {activeSubView === 'rbac' && renderRBAC()}
        {activeSubView === 'api' && renderAPIWebhooks()}
      </div>
    </div>
  );
};
return SystemAdmin;
})();

/* ===== InterviewScheduler ===== */
const InterviewScheduler = (() => {
interface InterviewSchedulerProps {
  user: User;
}

const InterviewScheduler: React.FC<InterviewSchedulerProps> = ({ user }) => {
  const isAgent = user.role === 'AGENT';
  const { data: slots, isLoading, refresh } = useApi(api.getInterviewSlots);
  const { data: allStudents, isLoading: studentsLoading } = useApi(api.getStudents);
  const [selectedSlot, setSelectedSlot] = useState<InterviewSlot | null>(null);
  const [selectedStudentId, setSelectedStudentId] = useState<string | null>(null);
  const [booking, setBooking] = useState(false);
  const [success, setSuccess] = useState(false);

  const students = isAgent && user.agencyId 
    ? allStudents?.filter(s => s.agencyId === user.agencyId) 
    : allStudents;

  const selectedStudent = students?.find(s => s.id === selectedStudentId);

  const handleBook = async () => {
    if (!selectedSlot || !selectedStudent) return;
    setBooking(true);
    try {
      await api.bookInterviewSlot(selectedSlot.id, selectedStudent.id, selectedStudent.name);
      setSuccess(true);
      refresh();
      setTimeout(() => {
        setSuccess(false);
        setSelectedSlot(null);
      }, 3000);
    } catch (error) {
      console.error('Booking failed:', error);
    } finally {
      setBooking(false);
    }
  };

  const availableSlots = slots?.filter(s => s.status === 'Available') || [];

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Interjú Időpont Foglalás</h2>
          <p className="text-slate-500 mt-1">Válassz egy szabad időpontot a felvételi interjúhoz.</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2 px-3 py-1.5 bg-indigo-50 text-indigo-600 rounded-lg border border-indigo-100">
             <ICONS.Calendar size={16} />
             <span className="text-[10px] font-bold uppercase tracking-widest">Elérhető időpontok: {availableSlots.length}</span>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div className="lg:col-span-2 space-y-6">
          {isLoading ? (
            <div className="flex items-center justify-center h-64">
              <div className="w-8 h-8 border-4 border-indigo-600 border-t-transparent rounded-full animate-spin"></div>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              {availableSlots.map((slot) => (
                <div 
                  key={slot.id}
                  onClick={() => setSelectedSlot(slot)}
                  className={`p-6 rounded-2xl border transition-all cursor-pointer group ${
                    selectedSlot?.id === slot.id 
                      ? 'bg-indigo-600 border-indigo-600 text-white shadow-xl shadow-indigo-100' 
                      : 'bg-white border-slate-100 text-slate-800 hover:border-indigo-300'
                  }`}
                >
                  <div className="flex items-start justify-between">
                    <div className="space-y-1">
                      <p className={`text-xs font-bold uppercase tracking-widest ${selectedSlot?.id === slot.id ? 'text-indigo-200' : 'text-slate-400'}`}>
                        {new Date(slot.startTime).toLocaleDateString('hu-HU', { weekday: 'long', month: 'long', day: 'numeric' })}
                      </p>
                      <h4 className="text-xl font-bold">
                        {new Date(slot.startTime).toLocaleTimeString('hu-HU', { hour: '2-digit', minute: '2-digit' })} - {new Date(slot.endTime).toLocaleTimeString('hu-HU', { hour: '2-digit', minute: '2-digit' })}
                      </h4>
                      <p className={`text-sm ${selectedSlot?.id === slot.id ? 'text-indigo-100' : 'text-slate-500'}`}>
                        Interjúztató: {slot.interviewerName}
                      </p>
                    </div>
                    <div className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all ${
                      selectedSlot?.id === slot.id ? 'bg-white/20 text-white' : 'bg-slate-50 text-slate-400 group-hover:bg-indigo-50 group-hover:text-indigo-600'
                    }`}>
                      <ICONS.Clock size={20} />
                    </div>
                  </div>
                </div>
              ))}
              {availableSlots.length === 0 && (
                <div className="col-span-full p-12 bg-slate-50 rounded-3xl border border-dashed border-slate-200 text-center">
                  <ICONS.CalendarOff size={48} className="mx-auto text-slate-300 mb-4" />
                  <p className="text-slate-500 font-medium">Jelenleg nincs szabad időpont.</p>
                </div>
              )}
            </div>
          )}
        </div>

        <div className="space-y-6">
          <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm sticky top-8">
            <h3 className="text-xl font-bold text-slate-800 mb-6">Foglalás Összegzése</h3>
            
            {selectedSlot ? (
              <div className="space-y-6">
                <div className="space-y-2">
                  <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Jelentkező Kiválasztása</label>
                  <select 
                    value={selectedStudentId || ''} 
                    onChange={(e) => setSelectedStudentId(e.target.value)}
                    className="w-full bg-slate-50 border border-slate-100 rounded-xl px-4 py-3 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/20"
                  >
                    <option value="">Válasszon diákot...</option>
                    {students?.map(s => (
                      <option key={s.id} value={s.id}>{s.name}</option>
                    ))}
                  </select>
                </div>

                <div className="p-4 bg-slate-50 rounded-2xl border border-slate-100 space-y-3">
                  <div className="flex justify-between text-xs">
                    <span className="text-slate-500">Dátum:</span>
                    <span className="font-bold text-slate-800">{new Date(selectedSlot.startTime).toLocaleDateString('hu-HU')}</span>
                  </div>
                  <div className="flex justify-between text-xs">
                    <span className="text-slate-500">Időpont:</span>
                    <span className="font-bold text-slate-800">
                      {new Date(selectedSlot.startTime).toLocaleTimeString('hu-HU', { hour: '2-digit', minute: '2-digit' })}
                    </span>
                  </div>
                  <div className="flex justify-between text-xs">
                    <span className="text-slate-500">Interjúztató:</span>
                    <span className="font-bold text-slate-800">{selectedSlot.interviewerName}</span>
                  </div>
                  <div className="flex justify-between text-xs">
                    <span className="text-slate-500">Típus:</span>
                    <span className="font-bold text-indigo-600">Online (Teams)</span>
                  </div>
                </div>

                <div className="bg-amber-50 p-4 rounded-2xl border border-amber-100 flex gap-3">
                  <ICONS.Info size={18} className="text-amber-600 flex-shrink-0" />
                  <p className="text-[11px] text-amber-700 leading-relaxed">
                    A foglalás után automatikusan generálunk egy Teams linket, amit e-mailben is megkapsz.
                  </p>
                </div>

                {success ? (
                  <div className="bg-emerald-50 text-emerald-600 p-4 rounded-2xl border border-emerald-100 flex items-center gap-3 animate-in zoom-in duration-300">
                    <ICONS.CheckCircle size={20} />
                    <span className="text-sm font-bold">Sikeres foglalás!</span>
                  </div>
                ) : (
                  <button 
                    onClick={handleBook}
                    disabled={booking}
                    className="w-full bg-indigo-600 text-white py-4 rounded-2xl font-bold shadow-lg shadow-indigo-100 hover:bg-indigo-700 transition-all flex items-center justify-center gap-2 disabled:opacity-50"
                  >
                    {booking ? (
                      <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                    ) : (
                      <>Foglalás Megerősítése</>
                    )}
                  </button>
                )}
              </div>
            ) : (
              <div className="text-center py-12 space-y-4">
                <div className="w-16 h-16 bg-slate-50 rounded-full flex items-center justify-center mx-auto text-slate-300">
                  <ICONS.MousePointer2 size={24} />
                </div>
                <p className="text-sm text-slate-400">Válassz egy időpontot a listából a folytatáshoz.</p>
              </div>
            )}
          </div>

          {/* Teams Integration Preview */}
          <div className="bg-slate-900 rounded-3xl p-8 text-white relative overflow-hidden">
            <div className="absolute top-0 right-0 p-8 opacity-10">
              <ICONS.Video size={80} />
            </div>
            <h4 className="text-lg font-bold mb-2">Teams Integráció</h4>
            <p className="text-xs text-slate-400 leading-relaxed mb-6">
              Az időpontok automatikusan szinkronizálódnak az interjúztatók naptárával.
            </p>
            <div className="flex items-center gap-2 text-[10px] font-bold text-indigo-400 uppercase tracking-widest">
              <div className="w-2 h-2 bg-indigo-400 rounded-full animate-pulse" />
              Előkészítve szinkronizációra
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
return InterviewScheduler;
})();

/* ===== AdmissionsHub + AdmissionsJourney (Felvételi folyamatok) ===== */
let JourneyShared = {};
/* Supabase szinkron a folyamatokhoz (megosztott tárolás eszközök/munkamenetek között) */
async function spSaveProc(ownerEmail, proc) {
  if (!window.sb || !proc || !proc.id) return;
  try {
    await sb.from('admission_processes').upsert({
      id: proc.id, owner_email: ownerEmail || null, step: proc.step || 0, max_reached: proc.maxReached || 0,
      done: !!proc.done, data: proc.data || {}, created_at: proc.createdAt || '', updated_at: new Date().toISOString()
    });
  } catch (e) {}
}
async function spDeleteProc(id) { if (!window.sb || !id) return; try { await sb.from('admission_processes').delete().eq('id', id); } catch (e) {} }
const spRow = (r) => ({ id: r.id, createdAt: r.created_at, step: r.step || 0, maxReached: r.max_reached || 0, done: !!r.done, data: r.data || {}, _owner: r.owner_email || 'demo', updatedAt: r.updated_at });

/* Lists read from admission_process_list (migration 09), a view identical to
   the table except that embedded file bytes are stripped out of data.docs.
   Selecting '*' from the table here meant every poll dragged the applicants'
   uploaded documents across the wire — measured at 12.5 MB / 3.6 s per call,
   every 12 seconds. The full row is fetched only when a process is opened. */
const SP_LIST_SOURCE = 'admission_process_list';
let SP_LIST_VIEW_OK = true;   // set false once, if migration 09 is not applied

async function spFetchProcs(ownerEmail) {
  if (!window.sb) return null;
  const query = (table) => {
    let q = sb.from(table).select('*');
    if (ownerEmail) q = q.eq('owner_email', ownerEmail);
    return q;
  };
  try {
    let data = null, error = null;
    if (SP_LIST_VIEW_OK) {
      ({ data, error } = await query(SP_LIST_SOURCE));
      // Remember a missing view so every later poll skips the failed probe.
      if (error) SP_LIST_VIEW_OK = false;
    }
    if (!SP_LIST_VIEW_OK) ({ data, error } = await query('admission_processes'));
    if (error || !Array.isArray(data)) return null;
    return data.map(spRow);
  } catch (e) { return null; }
}

/* The full row, including any document still embedded in data. Called when a
   process is opened, so the list never has to carry file bytes. */
async function spFetchProc(id) {
  if (!window.sb || !id) return null;
  try {
    const { data, error } = await sb.from('admission_processes').select('*').eq('id', id).maybeSingle();
    if (error || !data) return null;
    return spRow(data);
  } catch (e) { return null; }
}
async function spSaveMsg(m) { if (!window.sb || !m || !m.id) return; try { await sb.from('process_messages').upsert({ id: m.id, process_id: m.processId || null, owner_email: m.owner || null, applicant: m.applicant || null, sender: m.sender || null, subject: m.subject || null, preview: m.preview || null, tone: m.tone || null, attachments: m.attachments || [], read: !!m.read, date: m.date || '' }); } catch (e) {} }
async function spFetchMsgs(ownerEmail) {
  if (!window.sb) return null;
  try {
    let q = sb.from('process_messages').select('*');
    if (ownerEmail) q = q.eq('owner_email', ownerEmail);
    const { data, error } = await q;
    if (error || !Array.isArray(data)) return null;
    return data.map(r => ({ id: r.id, processId: r.process_id, owner: r.owner_email, applicant: r.applicant, sender: r.sender, subject: r.subject, preview: r.preview, tone: r.tone, attachments: r.attachments || [], read: !!r.read, date: r.date }));
  } catch (e) { return null; }
}
// `src` is either a data: URL (legacy inline document) or a signed Storage URL.
async function extractPdfText(src) {
  try {
    const pdfjs = await import('https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.min.mjs');
    pdfjs.GlobalWorkerOptions.workerSrc = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.worker.min.mjs';
    const bytes = await DOC_bytes(src);
    if (!bytes) return '';
    const pdf = await pdfjs.getDocument({ data: bytes }).promise;
    let text = ''; const pages = Math.min(pdf.numPages, 6);
    for (let n = 1; n <= pages; n++) { const page = await pdf.getPage(n); const tc = await page.getTextContent(); text += tc.items.map(it => it.str).join(' ') + '\n'; }
    return text.slice(0, 6000);
  } catch (e) { return ''; }
}
function PdfObject({ src }) {
  const containerRef = React.useRef(null);
  const [status, setStatus] = React.useState('loading');
  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const pdfjs = await import('https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.min.mjs');
        pdfjs.GlobalWorkerOptions.workerSrc = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@4.7.76/build/pdf.worker.min.mjs';
        const bytes = await DOC_bytes(src);
        if (cancelled || !bytes) return;
        const pdf = await pdfjs.getDocument({ data: bytes }).promise;
        if (cancelled) return;
        const container = containerRef.current;
        if (!container) return;
        container.innerHTML = '';
        const pages = Math.min(pdf.numPages, 10);
        for (let n = 1; n <= pages; n++) {
          const page = await pdf.getPage(n);
          const viewport = page.getViewport({ scale: 1.4 });
          const canvas = document.createElement('canvas');
          canvas.width = viewport.width; canvas.height = viewport.height;
          canvas.style.width = '100%'; canvas.style.height = 'auto';
          canvas.className = 'mb-3 rounded-lg border border-slate-200 shadow-sm bg-white';
          container.appendChild(canvas);
          await page.render({ canvasContext: canvas.getContext('2d'), viewport }).promise;
          if (cancelled) return;
        }
        setStatus('done');
      } catch (e) { setStatus('error'); }
    })();
    return () => { cancelled = true; };
  }, [src]);
  return (
    <div className="w-full overflow-auto bg-slate-100 rounded-xl p-3" style={{ maxHeight: '62vh' }}>
      {status === 'loading' && <div className="text-center text-slate-400 text-sm py-10">PDF betöltése…</div>}
      {status === 'error' && <div className="text-center text-red-500 text-sm py-10">A PDF nem jeleníthető meg. <a href={src} download target="_blank" rel="noreferrer" className="text-primary font-bold underline">Letöltés</a></div>}
      <div ref={containerRef}></div>
    </div>
  );
}

/* Resolves a stored document to a usable URL: inline data: URL for legacy
   entries, a short-lived signed URL for anything in Storage. */
function useDocSrc(entry) {
  const key = entry ? (entry.path || (entry.dataUrl ? 'inline' : '')) : '';
  const [src, setSrc] = React.useState('');
  React.useEffect(() => {
    let dead = false;
    setSrc('');
    if (!key) return;
    DOC_src(entry).then(u => { if (!dead) setSrc(u); }).catch(() => {});
    return () => { dead = true; };
  }, [key]);
  return src;
}

function DocViewer({ entry, fileName }) {
  const src = useDocSrc(entry);
  if (!src) return <div className="text-center text-slate-400 text-sm py-10">Dokumentum betöltése…</div>;
  return ((entry && entry.type) || '').indexOf('pdf') >= 0
    ? <PdfObject src={src} />
    : <img src={src} alt={fileName || ''} className="max-h-[60vh] mx-auto rounded-xl border border-slate-200" />;
}

function DocDownloadLink({ entry, fileName, className, children }) {
  const src = useDocSrc(entry);
  if (!src) return null;
  return <a href={src} download={fileName} target="_blank" rel="noreferrer" className={className}>{children}</a>;
}
const AdmissionsHub = (() => {

  const PROGRAMS = [
    { id: 'ibe',    code: 'BSc', name: 'International Business Economics',          faculty: 'Faculty of Economics and Business',           level: 'undergraduate', tuition: 3000, semesters: 8, ects: 240 },
    { id: 'ibe-on', code: 'BSc', name: 'International Business Economics — ONLINE', faculty: 'Faculty of Economics and Business',           level: 'undergraduate', tuition: 2600, semesters: 8, ects: 240 },
    { id: 'tour',   code: 'BSc', name: 'Tourism and Catering',                     faculty: 'Faculty of Economics and Business',           level: 'undergraduate', tuition: 3000, semesters: 8, ects: 240 },
    { id: 'bam',    code: 'BSc', name: 'Business Administration and Management',    faculty: 'Faculty of Economics and Business',           level: 'undergraduate', tuition: 3000, semesters: 8, ects: 240 },
    { id: 'cse',    code: 'BSc', name: 'Computer Science Engineering',             faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', tuition: 3400, semesters: 7, ects: 210 },
    { id: 'mech',   code: 'BSc', name: 'Mechanical Engineering',                   faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', tuition: 3400, semesters: 7, ects: 210 },
    { id: 'veh',    code: 'BSc', name: 'Vehicle Engineering',                      faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', tuition: 3400, semesters: 7, ects: 210 },
    { id: 'log',    code: 'BSc', name: 'Logistics Engineering',                    faculty: 'Faculty of Engineering and Computer Science', level: 'undergraduate', tuition: 3400, semesters: 7, ects: 210 },
    { id: 'hort',   code: 'BSc', name: 'Horticultural Engineering',               faculty: 'Faculty of Horticulture and Rural Development', level: 'undergraduate', tuition: 3200, semesters: 7, ects: 210 },
    { id: 'ree',    code: 'MA',  name: 'Regional and Environmental Economics',     faculty: 'Faculty of Economics and Business',           level: 'graduate', tuition: 3600, semesters: 4, ects: 120 },
    { id: 'mba',    code: 'MBA', name: 'Master of Business Administration',        faculty: 'Faculty of Economics and Business',           level: 'graduate', tuition: 4200, semesters: 4, ects: 120 },
    { id: 'mba-dd', code: 'MBA', name: 'MBA — Double Degree',                      faculty: 'Faculty of Economics and Business',           level: 'graduate', tuition: 4800, semesters: 4, ects: 120 },
    { id: 'phd',    code: 'PhD', name: 'Doctoral Program in Management & Business', faculty: 'Doctoral School of Management and Business',  level: 'graduate', tuition: 5000, semesters: 8, ects: 240 },
    { id: 'prep',   code: 'PC',  name: 'Preparatory English and Math course',      faculty: 'Preparatory Program',                         level: 'preparatory', tuition: 1800, semesters: 2, ects: 60 },
  ];
  const PROGRAM_GROUPS = [
    { key: 'undergraduate', label: 'Alapképzés (BSc)' },
    { key: 'graduate', label: 'Mesterképzés / Doktori (MA · MBA · PhD)' },
    { key: 'preparatory', label: 'Előkészítő kurzus' },
  ];
  const COUNTRIES = ['Afghanistan','Albania','Algeria','Angola','Argentina','Armenia','Australia','Austria','Azerbaijan','Bahrain','Bangladesh','Belarus','Belgium','Benin','Bolivia','Bosnia and Herzegovina','Brazil','Bulgaria','Burkina Faso','Cambodia','Cameroon','Canada','Chad','Chile','China','Colombia','Congo','Costa Rica','Croatia','Cuba','Cyprus','Czech Republic','Denmark','Dominican Republic','Ecuador','Egypt','El Salvador','Estonia','Ethiopia','Finland','France','Gabon','Georgia','Germany','Ghana','Greece','Guatemala','Guinea','Honduras','Hungary','Iceland','India','Indonesia','Iran','Iraq','Ireland','Israel','Italy','Jamaica','Japan','Jordan','Kazakhstan','Kenya','Kosovo','Kuwait','Kyrgyzstan','Laos','Latvia','Lebanon','Liberia','Libya','Lithuania','Luxembourg','Madagascar','Malawi','Malaysia','Mali','Malta','Mauritius','Mexico','Moldova','Mongolia','Montenegro','Morocco','Mozambique','Myanmar','Namibia','Nepal','Netherlands','New Zealand','Nicaragua','Niger','Nigeria','North Macedonia','Norway','Oman','Pakistan','Palestine','Panama','Paraguay','Peru','Philippines','Poland','Portugal','Qatar','Romania','Russia','Rwanda','Saudi Arabia','Senegal','Serbia','Sierra Leone','Singapore','Slovakia','Slovenia','Somalia','South Africa','South Korea','South Sudan','Spain','Sri Lanka','Sudan','Sweden','Switzerland','Syria','Taiwan','Tajikistan','Tanzania','Thailand','Togo','Tunisia','Turkey','Turkmenistan','Uganda','Ukraine','United Arab Emirates','United Kingdom','United States','Uruguay','Uzbekistan','Venezuela','Vietnam','Yemen','Zambia','Zimbabwe'];
  const DOC_TYPES = [
    { id: 'school',     label: 'Iskolai tanulmányi adatok', hint: 'Bizonyítvány / diploma / leckekönyv', Icon: Lucide.GraduationCap, ocr: false },
    { id: 'passport',   label: 'Útlevél',                   hint: 'Érvényes úti okmány adatoldala',       Icon: Lucide.BookUser,     ocr: true },
    { id: 'language',   label: 'Nyelvvizsga',               hint: 'Angol nyelvtudás igazolása (B2+)',     Icon: Lucide.Languages,    ocr: false },
    { id: 'motivation', label: 'Motivációs levél',          hint: 'Min. 1 oldal, angol nyelven',          Icon: Lucide.PenLine,      ocr: false },
    { id: 'internship', label: 'Szakmai gyakorlat',         hint: 'Igazolás (ha releváns)',               Icon: Lucide.Briefcase,    ocr: false, optional: true },
  ];
  const FEES = { application: 200, dormitorySemester: 1000, dormitoryDeposit: 450, bank: { name: 'MBH Bank Nyrt.', iban: 'HU10103000021327841900014888', swift: 'MKKBHUHB' } };
  const EXISTING = [
    { name: 'Ahmed Hassan', passport: 'A09918273', email: 'ahmed@test.com' },
    { name: 'Chen Wei', passport: 'E88123456', email: 'chen@test.com' },
  ];

  const rnd = (a, b) => Math.floor(Math.random() * (b - a + 1)) + a;
  const nz = (a, b) => { let v = 0; while (v === 0) v = rnd(a, b); return v; };
  function genSystem() {
    const x = rnd(-5, 5), y = rnd(-5, 5);
    let a1 = nz(1, 5), b1 = nz(1, 5), a2, b2;
    do { a2 = nz(1, 5); b2 = nz(1, 5); } while (a1 * b2 - a2 * b1 === 0);
    return { title: 'Egyenletrendszer', prompt: 'Oldd meg a következő egyenletrendszert!', lines: [a1 + 'x + ' + b1 + 'y = ' + (a1 * x + b1 * y), a2 + 'x + ' + b2 + 'y = ' + (a2 * x + b2 * y)], fields: [{ key: 'x', label: 'x =' }, { key: 'y', label: 'y =' }], check: (v) => Number(v.x) === x && Number(v.y) === y, sol: 'x = ' + x + ', y = ' + y };
  }
  function genEvaluate() {
    const a = rnd(1, 5), b = rnd(1, 4), k = rnd(2, 4), val = Math.pow(a - k * b, 2) + a * b;
    return { title: 'Kifejezés kiértékelése', prompt: 'Egyszerűsítsd, majd értékeld ki, ha a = ' + a + ' és b = ' + b + '!', lines: ['(a − ' + k + 'b)² + a·b'], fields: [{ key: 'r', label: 'Érték =' }], check: (v) => Number(v.r) === val, sol: '= ' + val };
  }
  function genQuadratic() {
    const b = nz(-4, 4), c = rnd(-6, 6), k = rnd(-3, 3), val = k * k + b * k + c;
    const bs = b < 0 ? '− ' + (-b) + 'x' : '+ ' + b + 'x', cs = c < 0 ? '− ' + (-c) : '+ ' + c;
    return { title: 'Másodfokú függvény', prompt: 'Adott az f(x) = x² ' + bs + ' ' + cs + '. Mennyi f(' + k + ')?', lines: ['f(x) = x² ' + bs + ' ' + cs], fields: [{ key: 'r', label: 'f(' + k + ') =' }], check: (v) => Number(v.r) === val, sol: '= ' + val };
  }
  function genLogTrig() {
    const n = rnd(2, 5), pow = Math.pow(2, n);
    const trigs = [{ t: 'sin 30°', v: 0.5 }, { t: 'sin 90°', v: 1 }, { t: 'cos 60°', v: 0.5 }, { t: 'cos 0°', v: 1 }, { t: 'sin 0°', v: 0 }];
    const tr = trigs[rnd(0, trigs.length - 1)], val = n + tr.v;
    return { title: 'Logaritmus és szögfüggvény', prompt: 'Értékeld ki a következő kifejezést!', lines: ['log₂(' + pow + ') + ' + tr.t], fields: [{ key: 'r', label: 'Érték =' }], check: (v) => Math.abs(Number(v.r) - val) < 1e-6, sol: '= ' + val };
  }
  const generateMathTest = () => [genSystem(), genEvaluate(), genQuadratic(), genLogTrig()];
  function mockPassportOCR(acc) {
    const L = 'ABCDEFGHJKMNPRTVWX';
    return { name: acc.fullName || 'GUEST APPLICANT', passportNumber: L[rnd(0, 17)] + L[rnd(0, 17)] + rnd(1000000, 9999999), country: acc.country || 'Nigeria', birthDate: acc.birthDate || '2002-06-21', confidence: rnd(94, 99) };
  }
  const makeFileNumber = (k) => 'NJE/2026/' + k + '/' + String(rnd(1, 9999)).padStart(4, '0');

  const STEP_DEFS = [
    { id: 'programs', label: 'Szakok', Icon: Lucide.GraduationCap },
    { id: 'documents', label: 'Dokumentumok', Icon: Lucide.Upload },
    { id: 'check', label: 'Ellenőrzés', Icon: Lucide.ShieldCheck },
    { id: 'math', label: 'Matek', Icon: Lucide.Calculator },
    { id: 'interview', label: 'Interjú', Icon: Lucide.Video },
    { id: 'letter', label: 'Felvételi levél', Icon: Lucide.FileCheck },
  ];
  const SLOTS = [
    { id: 's1', day: '2026. szept. 2.', time: '09:00', who: 'Dr. Kovács István' },
    { id: 's2', day: '2026. szept. 2.', time: '10:30', who: 'Dr. Kovács István' },
    { id: 's3', day: '2026. szept. 3.', time: '13:00', who: 'Szabó Péter' },
    { id: 's4', day: '2026. szept. 4.', time: '11:00', who: 'Szabó Péter' },
    { id: 's5', day: '2026. szept. 5.', time: '15:30', who: 'Dr. Nagy Éva' },
  ];

  const inputCls = 'w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder-slate-400 focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none transition-all';
  const labelCls = 'block text-xs font-bold text-slate-500 uppercase tracking-wide mb-1.5';

  function CountrySelect({ value, onChange }) {
    const [open, setOpen] = useState(false);
    const [q, setQ] = useState('');
    const list = COUNTRIES.filter(o => o.toLowerCase().includes((open ? q : '').toLowerCase())).slice(0, 80);
    return (
      <div className="relative">
        <label className={labelCls}>Állampolgárság</label>
        <div className="relative">
          <input className={inputCls + ' pr-9'} value={open ? q : (value || '')} placeholder="Kezdjen el gépelni…"
            onFocus={() => { setOpen(true); setQ(''); }} onBlur={() => setTimeout(() => setOpen(false), 150)}
            onChange={(e) => { setQ(e.target.value); setOpen(true); }} />
          <Lucide.ChevronsUpDown size={16} className="text-slate-400 absolute right-3 top-1/2 -translate-y-1/2 pointer-events-none" />
        </div>
        {open && (
          <div className="absolute z-30 mt-1 w-full max-h-56 overflow-auto bg-white border border-slate-200 rounded-xl shadow-xl py-1">
            {list.length ? list.map(o => (
              <button key={o} type="button" onMouseDown={(e) => { e.preventDefault(); onChange(o); setOpen(false); }}
                className="w-full text-left px-3.5 py-2 text-sm hover:bg-primary/5 flex items-center justify-between">
                <span className={value === o ? 'font-bold text-primary' : 'text-slate-700'}>{o}</span>
                {value === o && <Lucide.Check size={14} className="text-primary" />}
              </button>
            )) : <div className="px-3.5 py-2 text-sm text-slate-400">Nincs találat</div>}
          </div>
        )}
      </div>
    );
  }

  const AdmissionsJourney = ({ user, process, onChange, onExit }) => {
    const step = process.step || 0;
    const maxReached = process.maxReached || 0;
    const data = process.data || {};
    const done = process.done || false;
    const [mathQs, setMathQs] = useState(null);
    const [reviewing, setReviewing] = useState(false);
    const [previewDoc, setPreviewDoc] = useState(null);
    const [uploadMsg, setUploadMsg] = useState('');

    const setData = (u) => onChange({ data: (typeof u === 'function') ? u(data) : u });
    const setDone = (v) => onChange({ done: v });
    useEffect(() => {
      if (STEP_DEFS[step].id === 'math' && !mathQs) setMathQs(generateMathTest());
    }, [step]);

    const set = (patch) => onChange({ data: { ...data, ...patch } });
    const goTo = (i) => onChange({ step: i });
    const next = () => { const n = Math.min(step + 1, STEP_DEFS.length - 1); onChange({ step: n, maxReached: Math.max(maxReached, n) }); };
    const back = () => onChange({ step: Math.max(step - 1, 0) });
    const reset = () => { setMathQs(null); onChange({ step: 0, maxReached: 0, data: { account: data.account }, done: false }); };

    const acc = data.account || {};
    const docs = data.docs || {};
    const ex = data.extracted;
    const chk = data.check || {};
    const mt = data.math || {};
    const iv = data.interview || {};
    const readOnly = done;

    if (done && !reviewing) {
      return (
        <div className="bg-white p-12 rounded-3xl border border-slate-100 shadow-sm text-center max-w-xl mx-auto animate-in fade-in slide-in-from-bottom-4 duration-500">
          <div className="w-16 h-16 rounded-2xl bg-emerald-50 text-emerald-600 flex items-center justify-center mx-auto mb-5"><Lucide.CheckCheck size={32} /></div>
          <h3 className="text-2xl font-black text-slate-800">Jelentkezés lezárva</h3>
          <p className="text-slate-500 mt-2">A feltételes felvételi levelet kiállítottuk és iktattuk. Az interjú a Teams-ben létrejött.</p>
          <div className="mt-4 inline-flex px-4 py-2 bg-primary/10 text-primary rounded-xl text-xs font-bold">{(data.letter || {}).fileNumber || '—'}</div>
          <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
            <button onClick={() => { setReviewing(true); goTo(Math.max(0, STEP_DEFS.findIndex(s => s.id === 'documents'))); }} className="bg-primary text-white px-7 py-3 rounded-2xl font-bold hover:bg-primary/90 transition-all inline-flex items-center gap-2"><Lucide.FolderOpen size={18} /> Folyamat megnyitása</button>
            <button onClick={onExit} className="bg-white border border-slate-200 text-slate-600 px-5 py-3 rounded-2xl font-bold hover:bg-slate-50 transition-all inline-flex items-center gap-2"><Lucide.LayoutGrid size={18} /> Folyamatok áttekintése</button>
            <button onClick={reset} className="text-slate-400 hover:text-slate-600 px-3 py-3 font-bold text-sm inline-flex items-center gap-1.5"><Lucide.RotateCcw size={15} /> Újraindítás</button>
          </div>
        </div>
      );
    }

    /* ---- stepper ---- */
    const Stepper = () => (
      <div className="bg-white p-5 rounded-3xl border border-slate-100 shadow-sm mb-8 overflow-x-auto">
        <div className="flex items-center min-w-[680px]">
          {STEP_DEFS.map((s, i) => {
            const dn = done ? true : i < step, ac = i === step, re = done ? true : i <= maxReached;
            return (
              <React.Fragment key={s.id}>
                <button disabled={!re} onClick={() => re && goTo(i)} className="flex flex-col items-center gap-2 group">
                  <div className={'w-11 h-11 rounded-2xl flex items-center justify-center transition-all ' + (dn ? 'bg-emerald-500 text-white' : ac ? 'bg-primary text-white shadow-lg shadow-primary/20 scale-110' : re ? 'bg-slate-100 text-slate-400' : 'bg-slate-50 text-slate-300')}>
                    {dn ? <Lucide.Check size={18} /> : <s.Icon size={18} />}
                  </div>
                  <span className={'text-[10px] font-bold uppercase tracking-wide whitespace-nowrap ' + (ac ? 'text-primary' : 'text-slate-400')}>{s.label}</span>
                </button>
                {i < STEP_DEFS.length - 1 && <div className={'flex-1 h-0.5 mx-1 -mt-5 ' + (i < step ? 'bg-emerald-400' : 'bg-slate-100')}></div>}
              </React.Fragment>
            );
          })}
        </div>
      </div>
    );

    /* ---- step content ---- */
    const renderStep = () => {
      const id = STEP_DEFS[step].id;
      if (id === 'register') {
        const upd = (k, v) => set({ account: { ...acc, [k]: v } });
        return (
          <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm max-w-2xl">
            <h3 className="text-xl font-black text-slate-800 mb-1">Adatok megadása</h3>
            <p className="text-slate-500 text-sm mb-6">A megadott adatokat később az útlevél-ellenőrzés is felülírhatja.</p>
            <div className="grid sm:grid-cols-2 gap-5">
              <div className="sm:col-span-2"><label className={labelCls}>Teljes név</label><input className={inputCls} value={acc.fullName || ''} onChange={e => upd('fullName', e.target.value)} placeholder="Pl. Adaeze Okonkwo" /></div>
              <div><label className={labelCls}>E-mail</label><input className={inputCls} value={acc.email || ''} onChange={e => upd('email', e.target.value)} placeholder="nev@email.com" /></div>
              <div><label className={labelCls}>Telefonszám</label><input className={inputCls} value={acc.phone || ''} onChange={e => upd('phone', e.target.value)} placeholder="+36…" /></div>
              <CountrySelect value={acc.country} onChange={v => upd('country', v)} />
              <div><label className={labelCls}>Születési dátum</label><input type="date" className={inputCls} value={acc.birthDate || ''} onChange={e => upd('birthDate', e.target.value)} /></div>
            </div>
            <div className="flex items-center gap-2 mt-6 text-xs text-slate-400"><Lucide.ShieldCheck size={14} /> Az adatokat a GDPR szerint kezeljük.</div>
          </div>
        );
      }
      if (id === 'programs') {
        const sel = data.programs || [];
        const toggle = (pid) => set({ programs: sel.includes(pid) ? sel.filter(x => x !== pid) : [...sel, pid] });
        return (
          <div className="space-y-7">
            <div className="bg-white rounded-2xl border border-slate-100 shadow-sm p-5">
              <div className="flex items-center justify-between mb-3">
                <div className="flex items-center gap-2 text-sm font-bold text-slate-700"><Lucide.UserCircle size={16} className="text-primary" /> Jelentkező adatai</div>
                <span className="text-[11px] text-slate-400">A profilból</span>
              </div>
              <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-3 text-sm">
                <div><span className="text-xs text-slate-400">Teljes név</span><div className="font-bold text-slate-700">{acc.fullName || '—'}</div></div>
                <div><span className="text-xs text-slate-400">E-mail</span><div className="font-bold text-slate-700">{acc.email || '—'}</div></div>
                <div><span className="text-xs text-slate-400">Telefonszám</span><div className="font-bold text-slate-700">{acc.phone || '—'}</div></div>
                <div><span className="text-xs text-slate-400">Állampolgárság</span><div className="font-bold text-slate-700">{acc.country || '—'}</div></div>
                <div><span className="text-xs text-slate-400">Születési dátum</span><div className="font-bold text-slate-700">{acc.birthDate || '—'}</div></div>
              </div>
              <p className="text-[11px] text-slate-400 mt-3">Ezek az adatok a profilodból származnak. Módosítani a Profilom oldalon tudod.</p>
            </div>
            <p className="text-slate-500 text-sm">Válassza ki a szakokat — egyszerre több szakra is jelentkezhet. A bírálat szakonként történik.</p>
            {PROGRAM_GROUPS.map(g => (
              <div key={g.key}>
                <div className="text-xs font-bold uppercase tracking-wide text-slate-400 mb-3">{g.label}</div>
                <div className="grid sm:grid-cols-2 gap-3">
                  {PROGRAMS.filter(p => p.level === g.key).map(p => {
                    const on = sel.includes(p.id);
                    return (
                      <div key={p.id} onClick={() => { if (!readOnly) toggle(p.id); }} className={'bg-white rounded-2xl border p-4 flex items-start gap-3 transition-all ' + (readOnly ? 'cursor-default ' : 'cursor-pointer ') + (on ? 'border-primary ring-2 ring-primary/20' : 'border-slate-100 hover:border-slate-300')}>
                        <span className={'flex-none mt-0.5 w-5 h-5 rounded-md border-2 flex items-center justify-center ' + (on ? 'bg-primary border-primary' : 'border-slate-300')}>{on && <Lucide.Check size={13} className="text-white" />}</span>
                        <div className="min-w-0">
                          <div className="flex items-center gap-2"><span className="text-[10px] font-black px-1.5 py-0.5 rounded bg-slate-100 text-slate-600">{p.code}</span><span className="font-bold text-slate-800 text-sm leading-tight">{p.name}</span></div>
                          <div className="text-xs text-slate-400 mt-1">{p.faculty}</div>
                          <div className="text-xs text-slate-500 mt-1.5">{p.tuition.toLocaleString()} EUR / szemeszter · {p.semesters} szem. · {p.ects} ECTS</div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        );
      }
      if (id === 'documents') {
        const DETECTED = { passport: 'Útlevél (MRZ-sor felismerve)', school: 'Iskolai bizonyítvány / leckekönyv', language: 'Nyelvvizsga-bizonyítvány', motivation: 'Motivációs levél', internship: 'Munkáltatói / gyakorlati igazolás' };
        const aiCheck = (d, file) => {
          const okFormat = /pdf|image/.test(file.type || '');
          const tiny = file.size < 25 * 1024;
          const flags = [];
          if (!okFormat) flags.push('Nem szokványos fájlformátum (nem PDF/kép)');
          if (tiny) flags.push('A fájl gyanúsan kicsi a típushoz képest');
          const score = okFormat && !tiny ? rnd(88, 99) : rnd(48, 72);
          return { detected: DETECTED[d.id] || d.label, expected: d.label, match: true, verdict: score >= 80 ? 'authentic' : 'review', score, flags, checkedAt: todayStr() };
        };
        const aiExtract = (d, file) => {
          const base = { 'Fájl': file.name, 'Típus': (file.type || 'ismeretlen'), 'Méret': Math.max(1, Math.round(file.size / 1024)) + ' KB', 'Beolvasva': todayStr(), 'AI megbízhatóság': rnd(92, 99) + '%' };
          if (d.id === 'passport') return { ...base, 'Név': (acc.fullName || 'GUEST APPLICANT').toUpperCase(), 'Útlevélszám': 'P' + rnd(1000000, 9999999), 'Állampolgárság': acc.country || 'Nigeria', 'Lejárat': '2031-0' + rnd(1, 9) + '-1' + rnd(0, 9) };
          if (d.id === 'school') return { ...base, 'Intézmény': 'Federal Government College', 'Végzettség': 'Secondary School Certificate', 'Átlag (GPA)': (3 + Math.random()).toFixed(2), 'Végzés éve': 2024 - rnd(0, 3) };
          if (d.id === 'language') return { ...base, 'Vizsga': ['IELTS', 'TOEFL iBT', 'Duolingo'][rnd(0, 2)], 'Pontszám': 'B2 / ' + rnd(6, 8) + '.0', 'Kiállítva': '2025-0' + rnd(1, 9) + '-1' + rnd(0, 9) };
          if (d.id === 'motivation') return { ...base, 'Oldalszám': rnd(1, 3), 'Szószám': rnd(450, 900), 'Nyelv': 'angol', 'Kulcsszavak': 'motiváció, karriercél, NJE' };
          if (d.id === 'internship') return { ...base, 'Munkáltató': 'TechCorp Ltd.', 'Pozíció': 'Intern', 'Időtartam': rnd(3, 12) + ' hónap' };
          return base;
        };
        const onUpload = async (d, file) => {
          if (!file) return;

          // Over the limit: say so and keep whatever was uploaded before.
          // Never report success for a document we did not store.
          if (file.size > DOC_MAX_BYTES) {
            setUploadMsg({
              tone: 'error',
              text: d.label + ' — a fájl ' + DOC_fmtSize(file.size) + ', a megengedett legfeljebb '
                + DOC_fmtSize(DOC_MAX_BYTES) + '. Kérjük, tömörítsd vagy csökkentsd a felbontását, és töltsd fel újra.',
            });
            setTimeout(() => setUploadMsg(''), 8000);
            return;
          }

          const finish = (stored) => {
            const nd = { ...docs, [d.id]: { fileName: file.name, status: 'uploaded', type: file.type, size: file.size, ...stored } };
            const patch = { docs: nd, aiExtracts: { ...(data.aiExtracts || {}), [d.id]: aiExtract(d, file) }, aiChecks: { ...(data.aiChecks || {}), [d.id]: aiCheck(d, file) } };
            if (d.ocr) patch.extracted = mockPassportOCR(acc);
            set(patch);
            setUploadMsg({ tone: 'ok', text: d.label + ' — sikeresen feltöltve (' + DOC_fmtSize(file.size) + ')' });
            setTimeout(() => setUploadMsg(''), 3000);
          };

          setUploadMsg({ tone: 'busy', text: d.label + ' — feltöltés folyamatban…' });
          // currentUser.id is the Supabase auth uid, which is also the first
          // path segment the Storage policies check.
          const authId = (user && user.id) || null;
          try {
            const path = await DOC_upload(file, authId, process && process.id, d.id);
            finish({ path });
            return;
          } catch (e) {
            // Storage not set up yet (migration 08) or upload rejected: keep the
            // old inline behaviour for small files so the demo still works, and
            // be explicit when the file is too large to inline.
            console.warn('Document upload to Storage failed, falling back to inline.', e);
            if (file.size > DOC_INLINE_FALLBACK_BYTES) {
              setUploadMsg({
                tone: 'error',
                text: d.label + ' — a dokumentumtár jelenleg nem elérhető, így ez a fájl most nem menthető el. Próbáld újra később, vagy tölts fel legfeljebb '
                  + DOC_fmtSize(DOC_INLINE_FALLBACK_BYTES) + ' méretűt.',
              });
              setTimeout(() => setUploadMsg(''), 9000);
              return;
            }
          }
          const reader = new FileReader();
          reader.onload = () => finish({ dataUrl: reader.result });
          reader.onerror = () => {
            setUploadMsg({ tone: 'error', text: d.label + ' — a fájl beolvasása nem sikerült.' });
            setTimeout(() => setUploadMsg(''), 6000);
          };
          reader.readAsDataURL(file);
        };
        const setEx = (k, v) => set({ extracted: { ...ex, [k]: v } });
        return (
          <div className="grid lg:grid-cols-2 gap-6">
            <div className="space-y-3">
              <p className="text-[11px] font-bold text-slate-400 flex items-center gap-1.5 px-1">
                <Lucide.Info size={13} className="flex-none" />
                PDF vagy kép, dokumentumonként legfeljebb {DOC_fmtSize(DOC_MAX_BYTES)}.
              </p>
              {DOC_TYPES.map(d => {
                const up = docs[d.id] && docs[d.id].fileName;
                return (
                  <div key={d.id} className="bg-white p-4 rounded-2xl border border-slate-100 shadow-sm flex items-center gap-4">
                    <span className={'flex-none w-11 h-11 rounded-xl flex items-center justify-center ' + (up ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-50 text-slate-400')}>{up ? <Lucide.CheckCircle2 size={22} /> : <d.Icon size={22} />}</span>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap"><span className="font-bold text-slate-800 text-sm">{d.label}</span>{d.optional && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-slate-100 text-slate-500">opcionális</span>}{d.ocr && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-primary/10 text-primary inline-flex items-center gap-1"><Lucide.Sparkles size={10} /> AI</span>}</div>
                      <div className="text-xs text-slate-400 mt-0.5 truncate">{up ? docs[d.id].fileName : d.hint}</div>
                      {up && (data.aiChecks || {})[d.id] && (() => { const c = data.aiChecks[d.id]; const ok = c.verdict === 'authentic'; return <div className={'mt-1 text-[10px] font-bold inline-flex items-center gap-1 ' + (ok ? 'text-emerald-600' : 'text-amber-600')}>{ok ? <Lucide.ShieldCheck size={11} /> : <Lucide.AlertTriangle size={11} />} AI: {c.detected} · {ok ? 'valódinak tűnik' : 'ellenőrzés alatt'}</div>; })()}
                    </div>
                    <div className="flex items-center gap-1.5">
                      {up && <button onClick={() => setPreviewDoc({ d, fileName: docs[d.id].fileName, entry: docs[d.id] })} className="px-3 py-1.5 rounded-lg text-xs font-bold text-slate-600 bg-slate-100 hover:bg-slate-200 inline-flex items-center gap-1.5"><Lucide.Eye size={13} /> Megtekintés</button>}
                      {!readOnly && <label className={'px-3 py-1.5 rounded-lg text-xs font-bold inline-flex items-center gap-1.5 cursor-pointer ' + (up ? 'text-slate-500 hover:bg-slate-100' : 'bg-primary/10 text-primary hover:bg-primary/20')}>{up ? <><Lucide.RefreshCw size={13} /> Csere</> : <><Lucide.Upload size={13} /> Feltöltés</>}<input type="file" accept="application/pdf,image/*" className="hidden" onChange={e => { onUpload(d, e.target.files && e.target.files[0]); e.target.value = ''; }} /></label>}
                    </div>
                  </div>
                );
              })}
            </div>
            <div>
              {ex ? (
                <div className="bg-white p-5 rounded-2xl border border-slate-100 shadow-sm">
                  <div className="flex items-center justify-between mb-4"><div className="flex items-center gap-2 font-bold text-slate-800"><Lucide.Sparkles size={18} className="text-primary" /> Kinyert adatok</div><span className="text-[10px] font-bold px-2 py-1 rounded-full bg-emerald-50 text-emerald-700">{ex.confidence}% biztos</span></div>
                  <p className="text-xs text-slate-400 mb-4">Az útlevélből automatikusan kinyert mezők — ellenőrizhető és javítható.</p>
                  <div className="space-y-3">
                    <div><label className={labelCls}>Név (útlevél szerint)</label><input className={inputCls} value={ex.name || ''} disabled={readOnly} onChange={e => setEx('name', e.target.value)} /></div>
                    <div><label className={labelCls}>Útlevélszám</label><input className={inputCls} value={ex.passportNumber || ''} disabled={readOnly} onChange={e => setEx('passportNumber', e.target.value)} /></div>
                    <div className="grid grid-cols-2 gap-3"><div><label className={labelCls}>Ország</label><input className={inputCls} value={ex.country || ''} disabled={readOnly} onChange={e => setEx('country', e.target.value)} /></div><div><label className={labelCls}>Szül. dátum</label><input type="date" className={inputCls} value={ex.birthDate || ''} disabled={readOnly} onChange={e => setEx('birthDate', e.target.value)} /></div></div>
                  </div>
                </div>
              ) : (
                <div className="bg-white p-8 rounded-2xl border border-dashed border-slate-200 flex flex-col items-center justify-center text-center h-full min-h-[220px]">
                  <Lucide.ScanLine size={32} className="text-slate-300 mb-3" />
                  <div className="font-bold text-slate-500">AI adatkinyerés</div>
                  <p className="text-xs text-slate-400 mt-1 max-w-xs">Töltse fel az útlevelet — a rendszer kiolvassa a nevet, útlevélszámot és állampolgárságot.</p>
                </div>
              )}
            </div>
          </div>
        );
      }
      if (id === 'check') {
        const reqV = DOC_TYPES.filter(d => !d.optional);
        const verified = reqV.every(d => docs[d.id] && docs[d.id].fileName && docs[d.id].verified);
        return (
          <div className="max-w-2xl space-y-5">
            <div className={'rounded-2xl p-5 border flex items-start gap-4 ' + (verified ? 'bg-emerald-50 border-emerald-200' : 'bg-amber-50 border-amber-200')}>
              <span className={'w-11 h-11 rounded-xl flex items-center justify-center flex-none ' + (verified ? 'bg-emerald-100 text-emerald-600' : 'bg-amber-100 text-amber-600')}>{verified ? <Lucide.ShieldCheck size={22} /> : <Lucide.Clock size={22} />}</span>
              <div>
                <div className={'font-black ' + (verified ? 'text-emerald-800' : 'text-amber-800')}>{verified ? 'Dokumentumok jóváhagyva' : 'Ellenőrzés folyamatban'}</div>
                <p className={'text-sm mt-0.5 ' + (verified ? 'text-emerald-600' : 'text-amber-700')}>{verified ? 'Az ügyintéző jóváhagyta a feltöltött dokumentumokat. Folytathatja a jelentkezést.' : 'A feltöltött dokumentumokat az ügyintéző ellenőrzi és hitelesíti. Kérjük, várjon a jóváhagyásra — az üzenetek között értesítjük.'}</p>
              </div>
            </div>
            <div className="bg-white p-5 rounded-2xl border border-slate-100 shadow-sm">
              <div className="font-bold text-slate-800 mb-4 flex items-center gap-2"><Lucide.ListChecks size={18} className="text-primary" /> Dokumentumok állapota</div>
              <div className="space-y-2.5">
                {DOC_TYPES.map(d => {
                  const up = docs[d.id] && docs[d.id].fileName; const dv = up && docs[d.id].verified;
                  const st = !up ? (d.optional ? 'none' : 'missing') : (dv ? 'verified' : 'pending');
                  const cfg = { verified: { b: 'bg-emerald-50 text-emerald-700', l: 'hitelesítve', c: 'text-emerald-500' }, pending: { b: 'bg-amber-50 text-amber-700', l: 'felülvizsgálat alatt', c: 'text-amber-500' }, missing: { b: 'bg-red-50 text-red-600', l: 'hiányzik', c: 'text-red-400' }, none: { b: 'bg-slate-100 text-slate-500', l: 'nincs', c: 'text-slate-300' } }[st];
                  return (
                    <div key={d.id} className="flex items-center gap-3 py-1.5">
                      {st === 'verified' ? <Lucide.ShieldCheck size={18} className={cfg.c} /> : <Lucide.CheckCircle2 size={18} className={cfg.c} />}
                      <span className="text-sm font-medium text-slate-700 flex-1">{d.label}</span>
                      <span className={'text-[10px] font-bold px-2 py-0.5 rounded-full ' + cfg.b}>{cfg.l}</span>
                    </div>
                  );
                })}
              </div>
              <p className="text-xs text-slate-400 mt-4 flex items-center gap-1.5"><Lucide.Info size={13} /> A dokumentumok hitelességét egyetemi ügyintéző ellenőrzi és hagyja jóvá.</p>
            </div>
          </div>
        );
      }
      if (id === 'math') {
        if (!mathQs) return <div className="text-slate-400 text-sm">Feladatok generálása…</div>;
        const setAns = (qi, key, v) => set({ math: { ...mt, answers: { ...(mt.answers || {}), [qi + '.' + key]: v } } });
        return (
          <div className="space-y-4">
            <p className="text-slate-500 text-sm">Négy feladat, véletlenszerűen generálva. A megfeleléshez 4-ből legalább 3 helyes válasz kell.</p>
            {mathQs.map((q, qi) => {
              const v = {}; q.fields.forEach(f => { v[f.key] = (mt.answers || {})[qi + '.' + f.key]; });
              const ok = mt.submitted && q.check(v), bad = mt.submitted && !q.check(v);
              return (
                <div key={qi} className={'bg-white p-5 rounded-2xl border shadow-sm ' + (ok ? 'border-emerald-300' : bad ? 'border-red-300' : 'border-slate-100')}>
                  <div className="flex items-start gap-4">
                    <span className="flex-none w-8 h-8 rounded-lg bg-slate-900 text-white font-bold flex items-center justify-center text-sm">{qi + 1}</span>
                    <div className="flex-1 min-w-0">
                      <div className="text-xs font-bold uppercase tracking-wide text-primary mb-1">{q.title}</div>
                      <p className="text-slate-800 font-medium">{q.prompt}</p>
                      <div className="mt-3 font-mono text-lg text-slate-900 bg-slate-50 rounded-xl px-4 py-3 inline-block">{q.lines.map((ln, i) => <div key={i}>{ln}</div>)}</div>
                      <div className="mt-2 text-xs font-bold text-amber-600 inline-flex items-center gap-1.5"><Lucide.FlaskConical size={13} /> TESZT — helyes válasz: {q.sol}</div>
                      <div className="flex flex-wrap gap-4 mt-4 items-center">
                        {q.fields.map(f => (<label key={f.key} className="flex items-center gap-2"><span className="font-mono text-sm text-slate-600">{f.label}</span><input disabled={mt.submitted} value={(mt.answers || {})[qi + '.' + f.key] || ''} onChange={e => setAns(qi, f.key, e.target.value)} className="w-24 px-3 py-2 rounded-lg border border-slate-200 font-mono text-center focus:border-primary outline-none disabled:bg-slate-50" /></label>))}
                        {ok && <span className="text-xs font-bold text-emerald-600 inline-flex items-center gap-1"><Lucide.Check size={14} /> Helyes</span>}
                        {bad && <span className="text-xs font-bold text-red-600">Helyes: {q.sol}</span>}
                      </div>
                    </div>
                  </div>
                </div>
              );
            })}
            {mt.submitted && (
              <div className={'rounded-2xl p-5 flex items-center gap-4 ' + (mt.passed ? 'bg-emerald-50 border border-emerald-200' : 'bg-red-50 border border-red-200')}>
                <Lucide.Trophy size={26} className={mt.passed ? 'text-emerald-600' : 'text-red-600'} />
                <div className="flex-1"><div className={'font-black ' + (mt.passed ? 'text-emerald-800' : 'text-red-800')}>{mt.score} / 4 helyes — {mt.passed ? 'Sikeres!' : 'Nem érte el a 3 pontot'}</div><div className={'text-sm ' + (mt.passed ? 'text-emerald-600' : 'text-red-600')}>{mt.passed ? 'A matematika feltétel teljesült.' : 'Próbálja újra — új feladatokat generálunk.'}</div></div>
                {!mt.passed && <button onClick={() => { setMathQs(generateMathTest()); set({ math: { answers: {}, submitted: false } }); }} className="bg-slate-900 text-white px-5 py-2.5 rounded-xl font-bold text-sm inline-flex items-center gap-2"><Lucide.RefreshCw size={15} /> Új teszt</button>}
              </div>
            )}
          </div>
        );
      }
      if (id === 'interview') {
        const book = (s) => set({ interview: { slotId: s.id, slot: s, booked: true, teamsUrl: 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_' + Math.random().toString(36).slice(2, 11) } });
        if (!iv.booked) return (
          <div><p className="text-slate-500 text-sm mb-4">A foglaláskor automatikusan létrejön a Microsoft Teams meeting.</p>
            <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3">
              {SLOTS.map(s => (<div key={s.id} onClick={() => book(s)} className="bg-white p-4 rounded-2xl border border-slate-100 shadow-sm hover:border-primary/40 cursor-pointer transition-all"><div className="flex items-center gap-2 text-primary font-bold"><Lucide.Calendar size={16} /> {s.day}</div><div className="text-2xl font-black text-slate-800 mt-1">{s.time}</div><div className="text-xs text-slate-400 mt-1">{s.who}</div></div>))}
            </div></div>
        );
        return (
          <div className="bg-white p-7 rounded-3xl border border-slate-100 shadow-sm max-w-2xl">
            <div className="flex items-center gap-3 mb-5"><span className="w-12 h-12 rounded-2xl bg-emerald-50 text-emerald-600 flex items-center justify-center"><Lucide.CalendarCheck size={26} /></span><div><div className="font-black text-slate-800 text-lg">Interjú lefoglalva</div><div className="text-sm text-slate-500">Megerősítő e-mailt küldtünk.</div></div></div>
            <div className="grid sm:grid-cols-3 gap-4 mb-5">
              <div><div className="text-xs text-slate-400 font-bold uppercase">Időpont</div><div className="font-bold text-slate-800">{iv.slot.day}</div><div className="text-slate-600">{iv.slot.time}</div></div>
              <div><div className="text-xs text-slate-400 font-bold uppercase">Interjúztató</div><div className="font-bold text-slate-800">{iv.slot.who}</div></div>
              <div><div className="text-xs text-slate-400 font-bold uppercase">Platform</div><div className="font-bold text-slate-800 flex items-center gap-1.5"><Lucide.Video size={15} /> MS Teams</div></div>
            </div>
            <div className="rounded-xl bg-slate-50 border border-slate-100 p-3 flex items-center gap-3"><Lucide.Link size={16} className="text-slate-400" /><span className="font-mono text-xs text-slate-500 truncate flex-1">{iv.teamsUrl}</span><span className="text-[10px] font-bold px-2 py-1 rounded-full bg-sky-50 text-sky-700">automatikus</span></div>
            <button onClick={() => set({ interview: {} })} className="text-xs text-slate-400 hover:text-slate-600 mt-4">Időpont módosítása</button>
          </div>
        );
      }
      if (id === 'letter') {
        const selPrograms = (data.programs || []).map(pid => PROGRAMS.find(p => p.id === pid)).filter(Boolean);
        const L = data.letter || {};
        const admittedId = L.programId || (selPrograms[0] && selPrograms[0].id);
        const prog = PROGRAMS.find(p => p.id === admittedId) || selPrograms[0];
        if (!prog) return <div className="text-slate-400 text-sm">Válasszon legalább egy szakot a 2. lépésben.</div>;
        const name = (ex && ex.name) || acc.fullName || '—';
        const passport = (ex && ex.passportNumber) || '—';
        const country = (ex && ex.country) || acc.country || '—';
        const firstTwo = prog.tuition * 2, total = firstTwo + FEES.application + FEES.dormitorySemester;
        return (
          <div>
            <div className="flex flex-wrap items-center gap-4 mb-5 bg-white border border-slate-100 rounded-2xl p-4 shadow-sm">
              <span className="text-xs font-bold text-slate-500 uppercase">Felvett szak</span>
              <select value={admittedId} onChange={e => set({ letter: { ...L, programId: e.target.value } })} className="px-3 py-2 rounded-lg border border-slate-200 text-sm font-bold focus:border-primary outline-none">{selPrograms.map(p => <option key={p.id} value={p.id}>{p.code} · {p.name}</option>)}</select>
              <div className="flex-1"></div>
              <span className="text-[11px] font-bold px-3 py-1.5 rounded-full bg-primary/10 text-primary inline-flex items-center gap-1"><Lucide.Hash size={12} />{L.fileNumber}</span>
            </div>
            <div className="bg-white border border-slate-200 rounded-2xl shadow-sm mx-auto max-w-3xl">
              <div className="p-10 text-slate-800" style={{ fontFamily: 'Georgia, serif' }}>
                <div className="flex items-start justify-between pb-5 border-b-2 border-slate-900">
                  <div><div className="font-black text-slate-900">John von Neumann University</div><div className="text-xs text-slate-500">Neumann János Egyetem · Kecskemét, Hungary</div></div>
                  <div className="text-right text-xs text-slate-500"><div className="font-bold text-slate-700">Iktatószám</div><div className="font-mono">{L.fileNumber}</div></div>
                </div>
                <h3 className="text-center text-xl font-bold tracking-[0.18em] uppercase mt-8 mb-7" style={{ fontFamily: 'Inter, sans-serif' }}>Conditional Acceptance Letter</h3>
                <div className="space-y-1.5 text-[15px]"><p><strong>Date:</strong> {L.issuedAt}</p><p><strong>Name:</strong> {name}</p><p><strong>Passport number:</strong> {passport}</p><p><strong>Country:</strong> {country}</p></div>
                <p className="mt-6 text-[15px]">Dear {name},</p>
                <p className="mt-3 text-[15px]">Your application for admission to John von Neumann University has been reviewed. Your status is as follows:</p>
                <div className="my-4 pl-4 border-l-2 border-primary text-[15px] space-y-1"><p><strong>Academic program:</strong> [{prog.code}] {prog.name}</p><p><strong>Tuition fee:</strong> EUR {prog.tuition.toLocaleString()} / semester</p><p><strong>Length:</strong> {prog.semesters} semesters ({prog.ects} ECTS)</p></div>
                <p className="text-[15px]">You have submitted all necessary documents and met all stated requirements. We confirm that you are <strong>CONDITIONALLY ADMITTED</strong> to the program starting in September 2026. The Final Letter of Admission will be issued once your documents meet the legal requirements.</p>
                <p className="mt-4 font-bold text-[15px]">To receive the Final Letter of Admission, please transfer the following fees:</p>
                <table className="w-full text-[15px] my-3" style={{ fontFamily: 'Inter, sans-serif' }}><tbody>
                  <tr className="border-b border-slate-100"><td className="py-1.5">Application fee</td><td className="py-1.5 text-right font-semibold">EUR {FEES.application.toLocaleString()}</td></tr>
                  <tr className="border-b border-slate-100"><td className="py-1.5">Tuition fee — first two semesters</td><td className="py-1.5 text-right font-semibold">EUR {firstTwo.toLocaleString()}</td></tr>
                  <tr className="border-b border-slate-100"><td className="py-1.5">Dormitory fee — one semester</td><td className="py-1.5 text-right font-semibold">EUR {FEES.dormitorySemester.toLocaleString()}</td></tr>
                  <tr><td className="py-2 font-black">Altogether</td><td className="py-2 text-right font-black text-primary">EUR {total.toLocaleString()}</td></tr>
                </tbody></table>
                <p className="text-[15px]">Final payment deadline: <strong>15th July 2026</strong>. A dormitory deposit of EUR {FEES.dormitoryDeposit} is payable after arrival.</p>
                <div className="mt-4 rounded-xl bg-slate-50 p-4 text-[13px]" style={{ fontFamily: 'Inter, sans-serif' }}><div className="font-bold text-slate-700 mb-1">Bank details</div><div>Bank: {FEES.bank.name} · 1056 Budapest, Váci street 38., Hungary</div><div>Account holder: Neumann János Egyetem</div><div>IBAN: <span className="font-mono">{FEES.bank.iban}</span> · SWIFT: <span className="font-mono">{FEES.bank.swift}</span></div></div>
                <p className="mt-5 text-[15px]">Yours sincerely,</p>
                <div className="mt-8 flex items-end justify-between">
                  <div><div className="w-56 border-b border-slate-400 pb-1 mb-1 flex items-end h-12"><span className="text-primary italic text-lg" style={{ fontFamily: 'Georgia, serif' }}>Orsolya Krix</span></div><div className="text-sm font-bold text-slate-900" style={{ fontFamily: 'Inter, sans-serif' }}>Krix Orsolya</div><div className="text-xs text-slate-500" style={{ fontFamily: 'Inter, sans-serif' }}>International Office · John von Neumann University</div></div>
                  <div className="inline-flex items-center gap-1.5 text-[11px] font-bold text-slate-400 border border-dashed border-slate-300 rounded-lg px-2.5 py-1.5" style={{ fontFamily: 'Inter, sans-serif' }}><Lucide.PenTool size={13} /> Flintsign aláírás — később</div>
                </div>
              </div>
            </div>
          </div>
        );
      }
      return null;
    };

    /* ---- gating ---- */
    const reqDocsOk = DOC_TYPES.filter(d => !d.optional).every(d => docs[d.id] && docs[d.id].fileName);
    const canNext = (() => {
      const id = STEP_DEFS[step].id;
      if (id === 'register') return acc.fullName && acc.email && (acc.email || '').includes('@');
      if (id === 'programs') return (data.programs || []).length > 0;
      if (id === 'documents') return reqDocsOk;
      if (id === 'check') return DOC_TYPES.filter(d => !d.optional).every(d => docs[d.id] && docs[d.id].fileName && docs[d.id].verified);
      if (id === 'math') return mt.submitted && mt.passed;
      if (id === 'interview') return iv.booked;
      return true;
    })();

    const onPrimary = () => {
      const id = STEP_DEFS[step].id;
      if (id === 'check') { next(); return; }
      if (id === 'math' && !(mt.submitted && mt.passed)) {
        let score = 0; mathQs.forEach((q, qi) => { const v = {}; q.fields.forEach(f => { v[f.key] = (mt.answers || {})[qi + '.' + f.key]; }); if (q.check(v)) score++; });
        set({ math: { ...mt, submitted: true, score, passed: score >= 3 } });
        return;
      }
      if (id === 'letter') {
        if (!data.letter || !data.letter.fileNumber) { set({ letter: { ...(data.letter || {}), fileNumber: makeFileNumber('CAL'), issuedAt: '2026.06.29' } }); return; }
        setDone(true); return;
      }
      next();
    };
    const primaryLabel = (() => {
      const id = STEP_DEFS[step].id;
      if (id === 'register') return 'Fiók létrehozása';
      if (id === 'check') return canNext ? 'Tovább' : 'Jóváhagyásra vár';
      if (id === 'math') return (mt.submitted && mt.passed) ? 'Tovább' : 'Beadás és pontozás';
      if (id === 'letter') return (data.letter && data.letter.fileNumber) ? 'Folyamat lezárása' : 'Levél kiállítása';
      return 'Tovább';
    })();
    const mathAllFilled = STEP_DEFS[step].id === 'math' && mathQs ? mathQs.every((q, qi) => q.fields.every(f => ((mt.answers || {})[qi + '.' + f.key] || '') !== '')) : true;
    const primaryDisabled = (() => {
      const id = STEP_DEFS[step].id;
      if (id === 'math') return mt.submitted ? !mt.passed : !mathAllFilled;
      if (id === 'letter') return false;
      return !canNext;
    })();

    return (
      <div className="animate-in fade-in slide-in-from-bottom-4 duration-500">
        <button onClick={onExit} className="text-sm text-slate-400 hover:text-slate-600 mb-4 inline-flex items-center gap-1.5"><Lucide.ChevronLeft size={15} /> Folyamatok áttekintése</button>
        <div className="flex items-center justify-between mb-4">
          <div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-widest mb-1">Felvételi folyamat · {step + 1} / {STEP_DEFS.length}</p>
            <h3 className="text-2xl font-black text-slate-800">{STEP_DEFS[step].label === 'Adatok' ? 'Jelentkezői adatok' : STEP_DEFS[step].id === 'check' ? 'Dokumentum-ellenőrzés' : STEP_DEFS[step].id === 'math' ? 'Matematika szintfelmérő' : STEP_DEFS[step].id === 'letter' ? 'Conditional Acceptance Letter' : STEP_DEFS[step].id === 'documents' ? 'Dokumentumok feltöltése' : STEP_DEFS[step].id === 'programs' ? 'Szakválasztás' : 'Online interjú foglalása'}</h3>
          </div>
          <button onClick={reset} className="text-xs text-slate-400 hover:text-slate-600 inline-flex items-center gap-1.5"><Lucide.RotateCcw size={13} /> Újraindítás</button>
        </div>
        {done && reviewing && (
          <div className="mb-5 rounded-2xl bg-slate-900 text-white px-5 py-4 flex items-center justify-between gap-4">
            <div className="flex items-center gap-3"><Lucide.Eye size={18} /><div><div className="font-bold text-sm">Lezárt folyamat megtekintése</div><div className="text-xs text-white/60">Megnézheted a feltöltött dokumentumokat és a felvételi levelet.</div></div></div>
            <button onClick={() => setReviewing(false)} className="bg-white/15 hover:bg-white/25 text-white px-4 py-2 rounded-xl font-bold text-xs inline-flex items-center gap-1.5"><Lucide.X size={14} /> Bezárás</button>
          </div>
        )}
        <Stepper />
        {renderStep()}
        <div className="flex items-center justify-between mt-8 pt-6 border-t border-slate-100">
          <div>{step > 0 && <button onClick={back} className="text-slate-600 hover:bg-slate-100 px-5 py-2.5 rounded-xl font-bold text-sm inline-flex items-center gap-2"><Lucide.ChevronLeft size={16} /> Vissza</button>}</div>
          <div className="flex items-center gap-4">
            {STEP_DEFS[step].id === 'letter' && (data.letter && data.letter.fileNumber) && <button onClick={() => window.print()} className="text-slate-600 hover:bg-slate-100 px-5 py-2.5 rounded-xl font-bold text-sm inline-flex items-center gap-2"><Lucide.Printer size={16} /> Nyomtatás</button>}
            {done && reviewing ? (
              step < STEP_DEFS.length - 1
                ? <button onClick={next} className="bg-primary text-white px-7 py-3 rounded-2xl font-bold hover:bg-primary/90 transition-all inline-flex items-center gap-2 shadow-lg shadow-primary/20">Tovább <Lucide.ChevronRight size={18} /></button>
                : <button onClick={() => setReviewing(false)} className="bg-slate-900 text-white px-7 py-3 rounded-2xl font-bold hover:bg-slate-800 transition-all inline-flex items-center gap-2"><Lucide.Check size={18} /> Bezárás</button>
            ) : (
              <button onClick={onPrimary} disabled={primaryDisabled} className="bg-primary text-white px-7 py-3 rounded-2xl font-bold hover:bg-primary/90 disabled:opacity-40 disabled:cursor-not-allowed transition-all inline-flex items-center gap-2 shadow-lg shadow-primary/20">{primaryLabel} <Lucide.ChevronRight size={18} /></button>
            )}
          </div>
        </div>
        {uploadMsg && (() => {
          // Older call sites passed a plain string; treat that as success.
          const m = typeof uploadMsg === 'string' ? { tone: 'ok', text: uploadMsg } : uploadMsg;
          const skin = m.tone === 'error' ? 'bg-red-600' : m.tone === 'busy' ? 'bg-slate-800' : 'bg-emerald-600';
          return (
            <div className={'fixed bottom-6 right-6 z-50 max-w-sm text-white px-5 py-3 rounded-2xl shadow-xl flex items-start gap-2.5 ' + skin} role="status">
              <span className="flex-none mt-0.5">
                {m.tone === 'error' ? <Lucide.AlertTriangle size={18} />
                  : m.tone === 'busy' ? <Lucide.Loader2 size={18} className="animate-spin" />
                  : <Lucide.CheckCircle2 size={18} />}
              </span>
              <span className="font-bold text-sm leading-snug">{m.text}</span>
            </div>
          );
        })()}
        {previewDoc && (
          <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/50 backdrop-blur-sm" onClick={() => setPreviewDoc(null)}>
            <div className="bg-white rounded-2xl shadow-2xl w-full max-w-lg overflow-hidden" onClick={e => e.stopPropagation()}>
              <div className="p-4 border-b border-slate-100 flex items-center justify-between"><div className="font-bold text-slate-800 text-sm flex items-center gap-2"><previewDoc.d.Icon size={16} className="text-primary" /> {previewDoc.d.label}</div><button onClick={() => setPreviewDoc(null)} className="text-slate-400 hover:text-slate-700"><Lucide.X size={18} /></button></div>
              <div className="p-4 bg-slate-50">
                {previewDoc.entry && (previewDoc.entry.path || previewDoc.entry.dataUrl) ? (
                  <DocViewer entry={previewDoc.entry} fileName={previewDoc.fileName} />
                ) : (
                  <div className="bg-white border border-slate-200 rounded-xl mx-auto max-h-[55vh] aspect-[3/4] w-full max-w-xs flex flex-col items-center justify-center text-center p-6"><previewDoc.d.Icon size={48} className="text-slate-300 mb-4" /><div className="font-mono text-xs text-slate-400">{previewDoc.fileName}</div><div className="font-bold text-slate-700 mt-2">{previewDoc.d.label}</div>{previewDoc.d.id === 'passport' && ex && <div className="mt-4 text-xs text-slate-500 space-y-0.5"><div>{ex.name}</div><div>{ex.passportNumber}</div><div>{ex.country}</div></div>}<div className="mt-4 text-[10px] text-slate-300">Nincs csatolt fájl</div></div>
                )}
                {previewDoc.entry && (previewDoc.entry.path || previewDoc.entry.dataUrl) && <div className="mt-3 text-right"><DocDownloadLink entry={previewDoc.entry} fileName={previewDoc.fileName} className="bg-primary text-white px-4 py-2 rounded-lg text-sm font-bold inline-flex items-center gap-1.5"><Lucide.Download size={14} /> Letöltés</DocDownloadLink></div>}
              </div>
            </div>
          </div>
        )}
      </div>
    );
  };
  function seedProcesses() {
    return [
      { id: 'PROC-demo1', createdAt: '2026.06.20', step: 5, maxReached: 5, done: true, data: {
        account: { fullName: 'Adaeze Okonkwo', email: 'adaeze.okonkwo@example.com', phone: '+2348021234567', country: 'Nigeria', birthDate: '2003-02-14' },
        programs: ['ibe'],
        docs: { school: { fileName: 'iskolai_tanulmanyi_adatok.pdf', status: 'uploaded' }, passport: { fileName: 'utlevel.pdf', status: 'uploaded' }, language: { fileName: 'nyelvvizsga.pdf', status: 'uploaded' }, motivation: { fileName: 'motivacios_level.pdf', status: 'uploaded' }, internship: { fileName: 'szakmai_gyakorlat.pdf', status: 'uploaded' } },
        extracted: { name: 'ADAEZE OKONKWO', passportNumber: 'A12345678', country: 'Nigeria', birthDate: '2003-02-14', confidence: 98 },
        check: { duplicateChecked: true, duplicates: [], cleared: true, notes: 'Minden dokumentum rendben.' },
        math: { answers: {}, submitted: true, score: 4, passed: true },
        interview: { slotId: 's1', slot: { id: 's1', day: '2026. szept. 2.', time: '09:00', who: 'Dr. Kovács István' }, booked: true, teamsUrl: 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_adaeze01' },
        letter: { fileNumber: 'NJE/2026/CAL/0042', issuedAt: '2026.06.29', programId: 'ibe' },
      } },
      { id: 'PROC-demo2', createdAt: '2026.06.24', step: 3, maxReached: 3, done: false, data: {
        account: { fullName: 'Mehmet Yılmaz', email: 'mehmet.yilmaz@example.com', phone: '+905321234567', country: 'Turkey', birthDate: '2002-09-30' },
        programs: ['cse', 'mech'],
        docs: { school: { fileName: 'iskolai_tanulmanyi_adatok.pdf', status: 'uploaded' }, passport: { fileName: 'utlevel.pdf', status: 'uploaded' }, language: { fileName: 'nyelvvizsga.pdf', status: 'uploaded' }, motivation: { fileName: 'motivacios_level.pdf', status: 'uploaded' } },
        extracted: { name: 'MEHMET YILMAZ', passportNumber: 'U72910384', country: 'Turkey', birthDate: '2002-09-30', confidence: 96 },
        check: { duplicateChecked: true, duplicates: [], cleared: true, notes: '' },
        math: { answers: {}, submitted: false },
      } },
      { id: 'PROC-demo3', createdAt: '2026.06.27', step: 1, maxReached: 1, done: false, data: {
        account: { fullName: 'Linh Nguyen', email: 'linh.nguyen@example.com', phone: '+84901234567', country: 'Vietnam', birthDate: '2004-05-08' },
        programs: ['tour', 'ibe'],
        docs: { school: { fileName: 'iskolai_tanulmanyi_adatok.pdf', status: 'uploaded' }, passport: { fileName: 'utlevel.pdf', status: 'uploaded' } },
        extracted: { name: 'LINH NGUYEN', passportNumber: 'C04829173', country: 'Vietnam', birthDate: '2004-05-08', confidence: 95 },
      } },
    ];
  }

  const AdmissionsHub = ({ user }) => {
    const LS = 'nje_processes_' + ((user && user.email) || 'guest');
    const loadAll = () => { try { const v = JSON.parse(localStorage.getItem(LS)); return Array.isArray(v) ? v : null; } catch (e) { return null; } };
    const [processes, setProcesses] = useState(() => { const s = loadAll(); return Array.isArray(s) ? s.filter(p => !String(p.id || '').startsWith('PROC-demo') && !(p.data && p.data._cancelled)) : []; });
    const [openId, setOpenId] = useState(null);
    const [procsLoading, setProcsLoading] = useState(true);
    const [procsRefreshing, setProcsRefreshing] = useState(false);
    const firstSync = React.useRef(true);
    useEffect(() => {
      try { localStorage.setItem(LS, JSON.stringify(processes)); } catch (e) {}
      if (firstSync.current) { firstSync.current = false; return; }
      processes.forEach(p => spSaveProc((user && user.email) || 'guest', p));
    }, [processes]);
    // Megosztott (Supabase) folyamatok betöltése + automatikus frissítés (realtime + lekérdezés).
    useEffect(() => {
      let alive = true;
      const refetch = async (first) => {
        if (!alive) return;
        if (first) setProcsLoading(true); else setProcsRefreshing(true);
        const remote = await spFetchProcs((user && user.email) || null);
        if (!alive) return;
        if (!remote) { setProcsLoading(false); setProcsRefreshing(false); return; }
        const clean = remote.filter(p => !String(p.id || '').startsWith('PROC-demo') && !(p.data && p.data._cancelled));
        setProcesses(prev => {
          const byId = {}; prev.forEach(p => { byId[p.id] = p; });
          clean.forEach(r => { const l = byId[r.id]; if (!l || !l.updatedAt || (r.updatedAt && r.updatedAt >= l.updatedAt)) byId[r.id] = r; });
          return Object.values(byId);
        });
        setProcsLoading(false); setProcsRefreshing(false);
      };
      refetch(true);
      // Realtime (migration 04) already pushes every change, so this is only a
      // safety net for a dropped websocket — 12 s meant a needless round-trip
      // five times a minute for every open tab.
      const poll = setInterval(refetch, 60000);
      let channel = null;
      try {
        if (window.sb && sb.channel) {
          channel = sb.channel('ap_hub_' + ((user && user.email) || 'guest'))
            .on('postgres_changes', { event: '*', schema: 'public', table: 'admission_processes' }, refetch)
            .subscribe();
        }
      } catch (e) {}
      return () => { alive = false; clearInterval(poll); try { if (channel) sb.removeChannel(channel); } catch (e) {} };
    }, [user && user.email]);

    const updateProcess = (id, patch) => setProcesses(ps => ps.map(p => p.id === id ? { ...p, ...patch, updatedAt: new Date().toISOString() } : p));
    const addProcess = () => { const id = uid('PROC'); const ov = loadAccountOverride(user && user.email); const acc = { fullName: (user && user.name) || ov.name || '', email: (user && user.email) || '', phone: (user && user.phone) || ov.phone || '', country: (user && user.country) || ov.country || '', birthDate: (user && user.birthDate) || ov.birthDate || '' }; const p = { id, createdAt: todayStr(), step: 0, maxReached: 0, done: false, updatedAt: new Date().toISOString(), data: { account: acc } }; setProcesses(ps => [p, ...ps]); setOpenId(id); };
    const delProcess = (id) => { if (typeof window !== 'undefined' && window.confirm && !window.confirm('Biztosan megszakítja ezt a jelentkezést? Az ügyintéző látni fogja, hogy megszakította.')) return; const proc = processes.find(p => p.id === id); if (proc) spSaveProc((user && user.email) || 'guest', { ...proc, data: { ...(proc.data || {}), _cancelled: true, _cancelledAt: todayStr() } }); setProcesses(ps => ps.filter(p => p.id !== id)); };

    if (openId) {
      const proc = processes.find(p => p.id === openId);
      if (!proc) return null;
      return <AdmissionsJourney user={user} process={proc} onChange={(patch) => updateProcess(openId, patch)} onExit={() => setOpenId(null)} />;
    }

    return (
      <div className="animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="flex items-center justify-between mb-6">
          <div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-widest mb-1">Felvételi folyamatok</p>
            <h3 className="text-2xl font-black text-slate-800 flex items-center gap-3">
              Aktív jelentkezések {procsLoading ? <SkeletonBar w={34} h={22} className="rounded-lg" /> : `(${processes.length})`}
              <RefreshingBadge on={procsRefreshing} />
            </h3>
          </div>
          <button onClick={addProcess} className="bg-primary text-white px-5 py-2.5 rounded-2xl font-bold hover:bg-primary/90 inline-flex items-center gap-2 shadow-lg shadow-primary/20"><Lucide.Plus size={18} /> Új folyamat</button>
        </div>
        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {procsLoading && Array.from({ length: 3 }).map((_, i) => (
            <div key={'sk' + i} className="bg-white rounded-2xl border border-slate-100 shadow-sm p-5">
              <div className="w-11 h-11 rounded-xl bg-slate-100 animate-pulse" />
              <div className="mt-4 space-y-2">
                <SkeletonBar w="70%" h={14} />
                <SkeletonBar w="45%" h={11} />
              </div>
              <div className="mt-5 space-y-2">
                <SkeletonBar w="100%" h={6} className="rounded-full" />
                <SkeletonBar w="35%" h={10} />
              </div>
            </div>
          ))}
          {!procsLoading && processes.map(p => {
            const d = p.data || {};
            const nm = (d.extracted && d.extracted.name) || (d.account && d.account.fullName) || 'Új jelentkező';
            const progs = (d.programs || []).map(id => { const pr = PROGRAMS.find(x => x.id === id); return pr ? pr.code + ' ' + pr.name : null; }).filter(Boolean);
            const pct = p.done ? 100 : Math.round(((p.maxReached || 0) / (STEP_DEFS.length - 1)) * 100);
            const stLabel = p.done ? 'Felvéve · levél kiállítva' : (STEP_DEFS[p.step] ? STEP_DEFS[p.step].label : '—');
            return (
              <div key={p.id} onClick={() => { setOpenId(p.id); spFetchProc(p.id).then(full => { if (full) setProcesses(ps => ps.map(x => x.id === p.id ? { ...x, ...full } : x)); }); }} className="bg-white rounded-2xl border border-slate-100 shadow-sm p-5 hover:border-primary/40 hover:shadow-md cursor-pointer transition-all group">
                <div className="flex items-start justify-between">
                  <div className="w-11 h-11 rounded-xl bg-primary/10 text-primary flex items-center justify-center font-black">{(nm[0] || '?').toUpperCase()}</div>
                  <button onClick={(e) => { e.stopPropagation(); delProcess(p.id); }} className="text-slate-300 hover:text-red-500 opacity-0 group-hover:opacity-100 transition-all"><Lucide.Trash2 size={16} /></button>
                </div>
                <div className="font-bold text-slate-800 mt-3 truncate">{nm}</div>
                <div className="text-xs text-slate-400 truncate">{progs.length ? progs.join(' · ') : 'Nincs szak kiválasztva'}</div>
                <div className="mt-4">
                  <div className="flex items-center justify-between text-[11px] font-bold mb-1.5"><span className={p.done ? 'text-emerald-600' : 'text-primary'}>{stLabel}</span><span className="text-slate-400">{(p.done ? STEP_DEFS.length : (p.maxReached || 0) + 1)}/{STEP_DEFS.length} lépés</span></div>
                  <div className="h-1.5 bg-slate-100 rounded-full overflow-hidden"><div className={(p.done ? 'bg-emerald-500' : 'bg-primary') + ' h-full rounded-full transition-all'} style={{ width: pct + '%' }}></div></div>
                </div>
                <div className="flex items-center justify-between mt-4 pt-3 border-t border-slate-50">
                  <span className="text-[11px] text-slate-400">{p.createdAt || ''}</span>
                  <span className="text-xs font-bold text-primary inline-flex items-center gap-1 group-hover:gap-2 transition-all">{p.done ? 'Megnyitás' : 'Folytatás'} <Lucide.ChevronRight size={14} /></span>
                </div>
              </div>
            );
          })}
          <button onClick={addProcess} className="bg-slate-50 rounded-2xl border-2 border-dashed border-slate-200 p-5 flex flex-col items-center justify-center text-slate-400 hover:border-primary/40 hover:text-primary transition-all min-h-[180px]"><Lucide.Plus size={28} /><span className="font-bold text-sm mt-2">Új felvételi folyamat</span></button>
        </div>
      </div>
    );
  };
  JourneyShared = { PROGRAMS, STEP_DEFS, DOC_TYPES, COUNTRIES, seedProcesses };
  return AdmissionsHub;
})();

/* ===== StudentPortal ===== */
const StudentPortal = (() => {
interface StudentPortalProps {
  user: User;
}

const StudentPortal: React.FC<StudentPortalProps> = ({ user }) => {
  const [activeTab, setActiveTab] = useState<'dashboard' | 'application' | 'documents' | 'finance' | 'interviews' | 'messages' | 'profile' | 'recommendations' | 'visa' | 'journey'>('dashboard');
  const [showJourney, setShowJourney] = useState(false);
  const [student, setStudent] = useState<Student | null>(null);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [interviewSlots, setInterviewSlots] = useState<InterviewSlot[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [showVideoInterview, setShowVideoInterview] = useState(false);
  const [uploadingDocId, setUploadingDocId] = useState<string | null>(null);
  const [messages, setMessages] = useState([]);
  const [journeyProcs, setJourneyProcs] = useState([]);

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [students, allPayments, allInvoices, allSlots] = await Promise.all([
          api.getStudents(),
          api.getPayments(),
          api.getInvoices(),
          api.getInterviewSlots()
        ]);
        
        // Find the student record associated with this user email
        const studentData = students.find(s => s.email === user.email);
        setStudent(studentData || null);
        
        // Filter payments for this student
        if (studentData) {
          setPayments(allPayments.filter(p => p.studentName === studentData.name));
          setInvoices(allInvoices.filter(i => i.studentName === studentData.name));
        }
        
        setInterviewSlots(allSlots);
      } catch (error) {
        console.error('Failed to fetch student data:', error);
      } finally {
        setIsLoading(false);
      }
    };
    fetchData();
  }, [user.email]);

  const journeyKey = 'nje_processes_' + ((user && user.email) || 'guest');
  const messagesKey = 'nje_messages_' + ((user && user.email) || 'guest');
  const loadProcs = () => { try { const v = JSON.parse(localStorage.getItem(journeyKey)); return Array.isArray(v) ? v.filter(p => !String(p.id || '').startsWith('PROC-demo')) : []; } catch (e) { return []; } };
  const buildDefaultMessages = (procs) => {
    const out = [];
    procs.forEach(p => {
      const nm = (p.data && p.data.extracted && p.data.extracted.name) || (p.data && p.data.account && p.data.account.fullName) || 'Jelentkező';
      if (p.done) out.push({ id: 'msg-' + p.id, processId: p.id, applicant: nm, sender: 'Felvételi Iroda', subject: 'Feltételes felvételi levél kiállítva', preview: 'A Conditional Acceptance Letter (' + ((p.data.letter || {}).fileNumber || '') + ') elkészült és iktatva lett.', date: (p.data.letter || {}).issuedAt || '2026.06.29', read: false, tone: 'success' });
      else if ((p.step || 0) >= 4) out.push({ id: 'msg-' + p.id, processId: p.id, applicant: nm, sender: 'Felvételi Iroda', subject: 'Dokumentumok jóváhagyva — szintfelmérő következik', preview: 'A dokumentumellenőrzés sikeres. Kérjük, töltse ki a matematika szintfelmérőt.', date: p.createdAt || '2026.06.24', read: false, tone: 'action' });
      else out.push({ id: 'msg-' + p.id, processId: p.id, applicant: nm, sender: 'Felvételi Iroda', subject: 'Hiányzó dokumentum', preview: 'Kérjük, töltse fel a hiányzó dokumentumokat a folyamat folytatásához.', date: p.createdAt || '2026.06.27', read: false, tone: 'warning' });
    });
    out.push({ id: 'msg-welcome', processId: null, applicant: '', sender: 'UniPortal Rendszer', subject: 'Üdvözöljük a felvételi rendszerben', preview: 'Itt nyomon követheti az összes felvételi folyamatát és a kapcsolódó üzeneteket.', date: '2026.06.20', read: true, tone: 'info' });
    return out;
  };
  useEffect(() => {
    const procs = loadProcs();
    setJourneyProcs(procs);
    (async () => {
      const remote = await spFetchProcs(user.email);
      if (!remote) return;
      const clean = remote.filter(p => !String(p.id || '').startsWith('PROC-demo') && !(p.data && p.data._cancelled));
      if (clean.length) setJourneyProcs(prev => { const byId = {}; prev.forEach(p => { byId[p.id] = p; }); clean.forEach(p => { byId[p.id] = p; }); return Object.values(byId); });
    })();
    let msgs = null;
    try { msgs = JSON.parse(localStorage.getItem(messagesKey)); } catch (e) {}
    if (!Array.isArray(msgs)) { msgs = buildDefaultMessages(procs); try { localStorage.setItem(messagesKey, JSON.stringify(msgs)); } catch (e) {} }
    else { const clean = msgs.filter(m => !String(m.processId || '').startsWith('PROC-demo')); if (clean.length !== msgs.length) { msgs = clean; try { localStorage.setItem(messagesKey, JSON.stringify(msgs)); } catch (e) {} } }
    setMessages(msgs);
    (async () => {
      const remote = await spFetchMsgs(user.email);
      if (!remote) return;
      const clean = remote.filter(m => !String(m.processId || '').startsWith('PROC-demo'));
      if (clean.length) setMessages(prev => { const byId = {}; prev.forEach(m => byId[m.id] = m); clean.forEach(m => byId[m.id] = m); const merged = Object.values(byId).sort((a, b) => (b.date || '').localeCompare(a.date || '')); try { localStorage.setItem(messagesKey, JSON.stringify(merged)); } catch (e) {} return merged; });
    })();
  }, [activeTab, user.email]);
  const persistMessages = (n) => { try { localStorage.setItem(messagesKey, JSON.stringify(n)); } catch (e) {} return n; };
  const markRead = (id) => setMessages(ms => persistMessages(ms.map(m => m.id === id ? { ...m, read: true } : m)));
  const markAllRead = () => setMessages(ms => persistMessages(ms.map(m => ({ ...m, read: true }))));
  const unreadCount = messages.filter(m => !m.read).length;

  const handleUpload = (docId: string) => {
    setUploadingDocId(docId);
    setTimeout(() => {
      if (student && student.visaChecklist) {
        const updatedChecklist = student.visaChecklist.map(item => 
          item.id === docId ? { ...item, status: 'Uploaded' as const } : item
        );
        api.updateVisaChecklist(student.id, updatedChecklist).then(updatedStudent => {
          setStudent(updatedStudent);
          setUploadingDocId(null);
        });
      }
    }, 1500);
  };

  const handleBookInterview = async (slotId: string) => {
    if (!student) return;
    try {
      const updatedSlot = await api.bookInterviewSlot(slotId, student.id, student.name);
      setInterviewSlots(interviewSlots.map(s => s.id === slotId ? updatedSlot : s));
    } catch (error) {
      console.error('Failed to book interview:', error);
    }
  };

  const handleVideoInterviewComplete = async (videos: VideoInterview[]) => {
    if (!student) return;
    try {
      const evaluation = {
        ...student.evaluation,
        videos: videos,
        criteria: student.evaluation?.criteria || [],
        comments: student.evaluation?.comments || []
      };
      
      const updatedStudent = await api.updateStudent(student.id, { evaluation });
      setStudent(updatedStudent);
    } catch (error) {
      console.error('Failed to save video interview:', error);
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-96">
        <div className="w-10 h-10 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
      </div>
    );
  }

  if (!student) {
    return (
      <div className="max-w-7xl mx-auto p-4 sm:p-8">
        <AdmissionsHub user={user} />
      </div>
    );
  }

  const renderDashboard = () => {
    const SD = JourneyShared.STEP_DEFS || [];
    const PROGS = JourneyShared.PROGRAMS || [];
    const inProgress = journeyProcs.filter(p => !p.done).length;
    const accepted = journeyProcs.filter(p => p.done).length;
    const interviewing = journeyProcs.filter(p => !p.done && p.data && p.data.interview && p.data.interview.booked).length;
    const recentMsgs = [...messages].sort((a, b) => (a.read === b.read) ? 0 : (a.read ? 1 : -1)).slice(0, 4);
    const procName = (p) => (p.data && p.data.extracted && p.data.extracted.name) || (p.data && p.data.account && p.data.account.fullName) || 'Új jelentkező';
    const tiles = [
      { label: 'Folyamatban', val: inProgress, Icon: Lucide.Loader, tone: 'text-primary bg-primary/10' },
      { label: 'Interjú foglalva', val: interviewing, Icon: Lucide.Video, tone: 'text-sky-600 bg-sky-50' },
      { label: 'Felvéve', val: accepted, Icon: Lucide.CheckCircle2, tone: 'text-emerald-600 bg-emerald-50' },
      { label: 'Olvasatlan üzenet', val: unreadCount, Icon: Lucide.Mail, tone: 'text-amber-600 bg-amber-50' },
    ];
    return (
      <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
          {tiles.map((t, i) => (
            <div key={i} className="bg-white p-5 rounded-2xl border border-slate-100 shadow-sm">
              <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${t.tone}`}><t.Icon size={20} /></div>
              <div className="text-3xl font-black text-slate-800 mt-3">{t.val}</div>
              <div className="text-xs font-bold text-slate-400 uppercase tracking-wide">{t.label}</div>
            </div>
          ))}
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-2 space-y-4">
            <div className="flex items-center justify-between">
              <h4 className="font-bold text-slate-800 text-lg">Felvételi folyamataim</h4>
              <button onClick={() => setActiveTab('journey')} className="text-sm font-bold text-primary hover:underline inline-flex items-center gap-1">Összes <Lucide.ChevronRight size={15} /></button>
            </div>
            {journeyProcs.length === 0 && (
              <div className="bg-white p-8 rounded-2xl border border-dashed border-slate-200 text-center text-slate-400">Még nincs felvételi folyamat. <button onClick={() => setActiveTab('journey')} className="text-primary font-bold">Indíts egyet</button>.</div>
            )}
            <div className="grid sm:grid-cols-2 gap-4">
              {journeyProcs.map(p => {
                const nm = procName(p);
                const progs = ((p.data && p.data.programs) || []).map(id => { const pr = PROGS.find(x => x.id === id); return pr ? pr.code : null; }).filter(Boolean);
                const pct = p.done ? 100 : Math.round(((p.maxReached || 0) / Math.max(SD.length - 1, 1)) * 100);
                const stLabel = p.done ? 'Felvéve' : (SD[p.step] ? SD[p.step].label : '—');
                const procUnread = messages.filter(m => m.processId === p.id && !m.read).length;
                return (
                  <div key={p.id} onClick={() => setActiveTab('journey')} className="bg-white rounded-2xl border border-slate-100 shadow-sm p-5 hover:border-primary/40 hover:shadow-md cursor-pointer transition-all group">
                    <div className="flex items-start justify-between">
                      <div className="w-10 h-10 rounded-xl bg-primary/10 text-primary flex items-center justify-center font-black">{(nm[0] || '?').toUpperCase()}</div>
                      {procUnread > 0 && <span className="inline-flex items-center gap-1 text-[10px] font-bold text-amber-600 bg-amber-50 px-2 py-1 rounded-full"><Lucide.Mail size={11} /> {procUnread}</span>}
                    </div>
                    <div className="font-bold text-slate-800 mt-3 truncate">{nm}</div>
                    <div className="text-xs text-slate-400 truncate">{progs.length ? progs.join(' · ') : 'Nincs szak'}</div>
                    <div className="mt-3">
                      <div className="flex items-center justify-between text-[11px] font-bold mb-1.5"><span className={p.done ? 'text-emerald-600' : 'text-primary'}>{stLabel}</span><span className="text-slate-400">{(p.done ? SD.length : (p.maxReached || 0) + 1)}/{SD.length}</span></div>
                      <div className="h-1.5 bg-slate-100 rounded-full overflow-hidden"><div className={(p.done ? 'bg-emerald-500' : 'bg-primary') + ' h-full rounded-full'} style={{ width: pct + '%' }}></div></div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <h4 className="font-bold text-slate-800 text-lg">Üzenetek</h4>
              <button onClick={() => setActiveTab('messages')} className="text-sm font-bold text-primary hover:underline">Összes</button>
            </div>
            <div className="bg-white rounded-2xl border border-slate-100 shadow-sm divide-y divide-slate-50 overflow-hidden">
              {recentMsgs.length === 0 && <div className="p-6 text-sm text-slate-400 text-center">Nincs üzenet.</div>}
              {recentMsgs.map(m => (
                <div key={m.id} onClick={() => { markRead(m.id); if (m.processId) setActiveTab('messages'); }} className={`p-4 flex items-start gap-3 cursor-pointer hover:bg-slate-50 transition-colors ${!m.read ? 'bg-primary/5' : ''}`}>
                  <div className={`w-9 h-9 rounded-lg flex items-center justify-center shrink-0 ${m.tone === 'success' ? 'bg-emerald-50 text-emerald-600' : m.tone === 'warning' ? 'bg-amber-50 text-amber-600' : m.tone === 'action' ? 'bg-primary/10 text-primary' : 'bg-slate-100 text-slate-400'}`}><Lucide.Mail size={16} /></div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2"><span className={`text-xs truncate ${!m.read ? 'font-bold text-slate-900' : 'text-slate-500'}`}>{m.applicant || m.sender}</span><span className="text-[10px] text-slate-400 shrink-0">{m.date}</span></div>
                    <div className={`text-xs truncate ${!m.read ? 'font-bold text-slate-800' : 'text-slate-500'}`}>{m.subject}</div>
                  </div>
                  {!m.read && <span className="w-2 h-2 bg-primary rounded-full mt-1.5 shrink-0"></span>}
                </div>
              ))}
            </div>
            <div className="bg-white p-6 rounded-3xl border border-slate-100 shadow-sm">
              <h5 className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-4">Fontos dátumok</h5>
              <div className="space-y-4">
                <div className="flex items-center gap-3"><div className="w-8 h-8 bg-slate-50 rounded-lg flex items-center justify-center text-slate-400 text-xs font-bold">15</div><div><p className="text-xs font-bold text-slate-800">Befizetési határidő</p><p className="text-[10px] text-slate-400">2026. július 15.</p></div></div>
                <div className="flex items-center gap-3"><div className="w-8 h-8 bg-slate-50 rounded-lg flex items-center justify-center text-slate-400 text-xs font-bold">01</div><div><p className="text-xs font-bold text-slate-800">Szemeszter kezdete</p><p className="text-[10px] text-slate-400">2026. szeptember 01.</p></div></div>
              </div>
            </div>
          </div>
        </div>
      </div>
    );
  };

  const renderApplication = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <div className="flex justify-between items-center mb-8">
          <h3 className="text-xl font-bold text-slate-800">Jelentkezési Adatok</h3>
          <span className="px-4 py-1 bg-slate-100 text-slate-600 rounded-lg text-[10px] font-bold uppercase tracking-wider">
            Beküldve: {student.appliedAt}
          </span>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-12">
          <div className="space-y-6">
            <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Személyes Adatok</h4>
            <div className="space-y-4">
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Születési dátum</p>
                <p className="text-sm font-medium text-slate-800">{student.birthDate || 'Nincs megadva'}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Útlevélszám</p>
                <p className="text-sm font-medium text-slate-800">{student.passportNumber || 'Nincs megadva'}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Nem</p>
                <p className="text-sm font-medium text-slate-800">{student.gender === 'Male' ? 'Férfi' : student.gender === 'Female' ? 'Nő' : 'Egyéb'}</p>
              </div>
            </div>
          </div>

          <div className="space-y-6">
            <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Választott Program</h4>
            <div className="space-y-4">
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Szak megnevezése</p>
                <p className="text-sm font-medium text-slate-800">{student.program}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Tandíj</p>
                <p className="text-sm font-medium text-slate-800">€{student.tuitionFee.toLocaleString()} / szemeszter</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Kezdés</p>
                <p className="text-sm font-medium text-slate-800">2024. Szeptember</p>
              </div>
            </div>
          </div>

          <div className="space-y-6">
            <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest">Lakcím</h4>
            <div className="space-y-4">
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Ország</p>
                <p className="text-sm font-medium text-slate-800">{student.address?.country || student.country}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Város</p>
                <p className="text-sm font-medium text-slate-800">{student.address?.city || 'Nincs megadva'}</p>
              </div>
              <div>
                <p className="text-[10px] text-slate-400 uppercase font-bold">Utca, házszám</p>
                <p className="text-sm font-medium text-slate-800">{student.address?.street || 'Nincs megadva'}</p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest mb-6">Tanulmányi Előzmények</h4>
          <div className="space-y-6">
            {student.educationHistory?.map((edu, idx) => (
              <div key={idx} className="flex gap-4">
                <div className="w-10 h-10 bg-slate-50 text-slate-400 rounded-xl flex items-center justify-center shrink-0">
                  <ICONS.GraduationCap size={20} />
                </div>
                <div>
                  <p className="text-sm font-bold text-slate-800">{edu.institution}</p>
                  <p className="text-xs text-slate-500">{edu.degree} - {edu.fieldOfStudy}</p>
                  <p className="text-[10px] text-slate-400 mt-1">{edu.startDate} - {edu.endDate} • Átlag: {edu.grade}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest mb-6">Nyelvtudás</h4>
          <div className="space-y-6">
            {student.languageSkills?.map((lang, idx) => (
              <div key={idx} className="flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className="w-10 h-10 bg-slate-50 text-slate-400 rounded-xl flex items-center justify-center">
                    <ICONS.Globe size={20} />
                  </div>
                  <div>
                    <p className="text-sm font-bold text-slate-800">{lang.language}</p>
                    <p className="text-[10px] text-slate-400">{lang.certificate || 'Nincs nyelvvizsga'}</p>
                  </div>
                </div>
                <span className="px-3 py-1 bg-indigo-50 text-indigo-600 rounded-lg text-[10px] font-bold">
                  {lang.level}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <h4 className="text-xs font-black text-slate-400 uppercase tracking-widest mb-4">Motivációs Levél</h4>
        <p className="text-sm text-slate-600 leading-relaxed italic">
          "{student.personalStatement}"
        </p>
      </div>
    </div>
  );

  const renderRecommendations = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <div className="flex justify-between items-center mb-8">
          <div>
            <h3 className="text-xl font-bold text-slate-800">Ajánlólevelek</h3>
            <p className="text-sm text-slate-500 mt-1">Kérj ajánlást oktatóidtól vagy szakmai feletteseidtől.</p>
          </div>
          <button className="bg-slate-900 text-white px-6 py-3 rounded-xl text-sm font-bold hover:bg-black transition-all flex items-center gap-2">
            <ICONS.PlusCircle size={18} />
            Új Ajánló Hozzáadása
          </button>
        </div>

        <div className="grid grid-cols-1 gap-6">
          {student.recommendationLetters && student.recommendationLetters.length > 0 ? (
            student.recommendationLetters.map((letter) => (
              <div key={letter.id} className="p-6 border border-slate-100 rounded-2xl flex flex-col md:flex-row justify-between items-start md:items-center gap-6 group hover:border-primary/20 transition-all">
                <div className="flex items-center gap-4">
                  <div className="w-14 h-14 bg-slate-50 text-slate-400 rounded-2xl flex items-center justify-center shrink-0">
                    <ICONS.UserCheck size={28} />
                  </div>
                  <div>
                    <p className="font-bold text-slate-800">{letter.referee.name}</p>
                    <p className="text-xs text-slate-500">{letter.referee.position} • {letter.referee.institution}</p>
                    <p className="text-[10px] text-slate-400 mt-1 uppercase font-bold tracking-tighter">Kérve: {letter.requestedAt}</p>
                  </div>
                </div>
                
                <div className="flex items-center gap-4 w-full md:w-auto justify-between md:justify-end">
                  <div className="text-right">
                    <span className={`px-4 py-1.5 rounded-xl text-[10px] font-bold uppercase tracking-widest ${
                      letter.status === 'Verified' ? 'bg-emerald-100 text-emerald-700' :
                      letter.status === 'Received' ? 'bg-blue-100 text-blue-700' :
                      letter.status === 'Requested' ? 'bg-amber-100 text-amber-700' : 'bg-slate-100 text-slate-600'
                    }`}>
                      {letter.status === 'Verified' ? 'Ellenőrizve' :
                       letter.status === 'Received' ? 'Beérkezett' :
                       letter.status === 'Requested' ? 'Folyamatban' : letter.status}
                    </span>
                    {letter.receivedAt && <p className="text-[10px] text-slate-400 mt-1 font-bold italic">Beérkezett: {letter.receivedAt}</p>}
                  </div>
                  <button className="p-2 text-slate-300 hover:text-primary transition-colors">
                    <ICONS.Eye size={20} />
                  </button>
                </div>
              </div>
            ))
          ) : (
            <div className="text-center py-12 bg-slate-50 rounded-3xl border border-dashed border-slate-200">
              <ICONS.FileText size={48} className="mx-auto text-slate-300 mb-4" />
              <p className="text-slate-500 font-medium">Még nem kértél ajánlólevelet.</p>
            </div>
          )}
        </div>
      </div>

      <div className="bg-indigo-50 p-8 rounded-3xl border border-indigo-100 flex items-start gap-6">
        <div className="w-12 h-12 bg-indigo-100 text-indigo-600 rounded-2xl flex items-center justify-center shrink-0">
          <ICONS.Info size={24} />
        </div>
        <div>
          <h4 className="font-bold text-indigo-900 mb-2">Hogyan működik az ajánlás?</h4>
          <p className="text-sm text-indigo-800 leading-relaxed">
            Az ajánló hozzáadása után a rendszer automatikusan küld egy e-mailt a megadott címre egy egyedi linkkel. 
            Az ajánló ezen a linken keresztül töltheti fel a levelet vagy töltheti ki az online űrlapot. 
            Amint az ajánlás beérkezik, értesítést kapsz, és a felvételi iroda megkezdi a hitelesítést.
          </p>
        </div>
      </div>
    </div>
  );

  const renderVisa = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {student.visaApplication ? (
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <div className="flex flex-col md:flex-row justify-between items-start md:items-center gap-6 mb-8">
            <div>
              <h3 className="text-xl font-bold text-slate-800">Vízum Kérelem Folyamata</h3>
              <p className="text-sm text-slate-500 mt-1">Kövesse nyomon a vízumigénylésének aktuális állapotát.</p>
            </div>
            <div className={`px-6 py-2 rounded-2xl text-sm font-bold uppercase tracking-widest ${
              student.visaApplication.status === 'Approved' ? 'bg-emerald-100 text-emerald-700' :
              student.visaApplication.status === 'Rejected' ? 'bg-red-100 text-red-700' :
              student.visaApplication.status === 'In Progress' ? 'bg-blue-100 text-blue-700' : 'bg-slate-100 text-slate-600'
            }`}>
              {student.visaApplication.status}
            </div>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8 mb-12">
            <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
              <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-2">Típus</p>
              <p className="text-lg font-bold text-slate-800">{student.visaApplication.type}</p>
            </div>
            <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
              <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-2">Konzulátus</p>
              <p className="text-lg font-bold text-slate-800">{student.visaApplication.consulate || '---'}</p>
            </div>
            <div className="p-6 bg-slate-50 rounded-2xl border border-slate-100">
              <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-2">Várható döntés</p>
              <p className="text-lg font-bold text-slate-800">15-30 munkanap</p>
            </div>
          </div>

          <div className="space-y-4">
            <h4 className="font-bold text-slate-800 mb-4">Szükséges Dokumentumok</h4>
            {(student.visaChecklist || []).map((item) => (
              <div key={item.id} className="p-4 border border-slate-100 rounded-2xl flex items-center justify-between">
                <div className="flex items-center gap-4">
                  <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${
                    item.status === 'Verified' ? 'bg-emerald-50 text-emerald-600' :
                    item.status === 'Uploaded' ? 'bg-blue-50 text-blue-600' : 'bg-slate-50 text-slate-400'
                  }`}>
                    <ICONS.FileText size={20} />
                  </div>
                  <div>
                    <p className="text-sm font-bold text-slate-800">{item.label}</p>
                    <p className="text-[10px] text-slate-400 font-bold uppercase">{item.status}</p>
                  </div>
                </div>
                {item.status === 'Pending' && (
                  <button className="text-xs font-bold text-primary hover:underline">Feltöltés</button>
                )}
              </div>
            ))}
          </div>
        </div>
      ) : (
        <div className="bg-white p-12 rounded-3xl border border-slate-100 shadow-sm text-center">
          <ICONS.Flag size={64} className="mx-auto text-slate-200 mb-6" />
          <h3 className="text-xl font-bold text-slate-800 mb-2">Vízumügyintézés hamarosan</h3>
          <p className="text-slate-500 max-w-md mx-auto">
            A vízumügyintézési folyamat akkor kezdődik el, amikor a tandíj befizetése megtörtént és a felvételi iroda kiállította a befogadó nyilatkozatot.
          </p>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
        <div className="bg-indigo-600 p-8 rounded-3xl text-white shadow-xl shadow-indigo-100">
          <ICONS.Mic size={32} className="mb-6 opacity-50" />
          <h4 className="text-xl font-bold mb-2">Interjú Felkészülés</h4>
          <p className="text-indigo-100 text-sm leading-relaxed mb-6">
            Gyakorolja a leggyakoribb vízumkérdéseket interaktív felületünkön, és kapjon azonnali visszajelzést.
          </p>
          <button className="bg-white text-indigo-600 px-6 py-3 rounded-xl text-sm font-bold hover:bg-indigo-50 transition-all">
            Gyakorlás indítása
          </button>
        </div>
        
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <ICONS.Info size={32} className="mb-6 text-slate-300" />
          <h4 className="text-xl font-bold text-slate-800 mb-2">Fontos Tudnivalók</h4>
          <ul className="space-y-3">
            {[
              'Mindig eredeti dokumentumokat vigyen az interjúra.',
              'A vízumdíj nem visszatéríthető.',
              'Ellenőrizze az útlevél érvényességét (min. 6 hónap).'
            ].map((tip, i) => (
              <li key={i} className="flex items-start gap-3 text-sm text-slate-600">
                <span className="w-1.5 h-1.5 bg-primary rounded-full mt-1.5 shrink-0" />
                {tip}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );

  const renderDocuments = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <h3 className="text-xl font-bold text-slate-800 mb-6">Szükséges Dokumentumok</h3>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {student.visaChecklist?.map((item) => (
            <div key={item.id} className="p-6 border border-slate-100 rounded-2xl flex items-center justify-between group hover:border-primary/20 transition-all">
              <div className="flex items-center gap-4">
                <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${
                  item.status === 'Verified' ? 'bg-emerald-50 text-emerald-600' :
                  item.status === 'Uploaded' ? 'bg-blue-50 text-blue-600' :
                  item.status === 'Rejected' ? 'bg-red-50 text-red-600' : 'bg-slate-50 text-slate-400'
                }`}>
                  {item.status === 'Verified' ? <ICONS.CheckCircle size={24} /> : <ICONS.FileText size={24} />}
                </div>
                <div>
                  <p className="font-bold text-slate-800 text-sm">{item.label}</p>
                  <p className={`text-[10px] font-bold uppercase tracking-tighter ${
                    item.status === 'Verified' ? 'text-emerald-500' :
                    item.status === 'Uploaded' ? 'text-blue-500' :
                    item.status === 'Rejected' ? 'text-red-500' : 'text-slate-400'
                  }`}>{item.status}</p>
                </div>
              </div>
              
              {item.status === 'Pending' || item.status === 'Rejected' ? (
                <button 
                  onClick={() => handleUpload(item.id)}
                  disabled={uploadingDocId === item.id}
                  className="bg-slate-900 text-white px-4 py-2 rounded-xl text-xs font-bold hover:bg-black transition-all flex items-center gap-2"
                >
                  {uploadingDocId === item.id ? (
                    <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin"></div>
                  ) : <ICONS.Upload size={14} />}
                  Feltöltés
                </button>
              ) : (
                <button className="text-slate-300 hover:text-primary transition-colors">
                  <ICONS.Eye size={20} />
                </button>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  const renderFinance = () => {
    const pendingInvoices = invoices.filter(i => i.studentName === student.name && i.status !== 'Paid');
    
    return (
      <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-2 space-y-6">
            {/* Pending Items Section */}
            {pendingInvoices.length > 0 && (
              <div className="bg-white p-8 rounded-3xl border-2 border-amber-100 shadow-sm">
                <div className="flex items-center gap-3 mb-6">
                  <div className="w-10 h-10 bg-amber-50 text-amber-600 rounded-xl flex items-center justify-center">
                    <ICONS.AlertCircle size={20} />
                  </div>
                  <h3 className="text-xl font-bold text-slate-800">Befizetendő tételek</h3>
                </div>
                
                <div className="space-y-4">
                  {pendingInvoices.map(invoice => (
                    <div key={invoice.id} className="p-6 bg-slate-50 rounded-2xl border border-slate-100 flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
                      <div>
                        <p className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-1">Számla: {invoice.id}</p>
                        <h4 className="font-bold text-slate-800">Tandíj Előleg / Szemeszter díj</h4>
                        <p className="text-xs text-slate-500 mt-1 flex items-center gap-1">
                          <ICONS.Clock size={12} /> Határidő: {invoice.dueDate}
                        </p>
                      </div>
                      <div className="flex items-center gap-6 w-full md:w-auto justify-between md:justify-end">
                        <div className="text-right">
                          <p className="text-xl font-black text-slate-900">{invoice.amount.toLocaleString()} {invoice.currency}</p>
                          <span className={`text-[10px] font-bold uppercase ${invoice.status === 'Overdue' ? 'text-red-500' : 'text-amber-500'}`}>
                            {invoice.status === 'Overdue' ? 'Lejárt' : 'Fizetésre vár'}
                          </span>
                        </div>
                        <button 
                          onClick={() => setActiveTab('finance')} // In a real app, this would open the payment portal
                          className="bg-primary text-white px-6 py-2 rounded-xl text-sm font-bold shadow-lg shadow-primary/10 hover:bg-primary/90 transition-all"
                        >
                          Fizetés
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
              <h3 className="text-xl font-bold text-slate-800 mb-6">Pénzügyi Áttekintés</h3>
            <div className="space-y-4">
              <div className="p-6 bg-slate-50 rounded-2xl flex items-center justify-between">
                <div>
                  <p className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-1">Tandíj Összege</p>
                  <p className="text-3xl font-black text-slate-900">€{student.tuitionFee.toLocaleString()}</p>
                </div>
                <div className={`px-4 py-2 rounded-xl text-xs font-bold uppercase ${student.status === 'Paid' ? 'bg-emerald-100 text-emerald-700' : 'bg-amber-100 text-amber-700'}`}>
                  {student.status === 'Paid' ? 'Befizetve' : 'Fizetésre vár'}
                </div>
              </div>
              
              {student.status !== 'Paid' && (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <button className="p-6 border-2 border-primary/20 rounded-2xl flex flex-col items-center gap-3 hover:bg-primary/5 transition-all group">
                    <ICONS.CreditCard size={32} className="text-primary" />
                    <span className="font-bold text-slate-800">Online Fizetés (Stripe)</span>
                    <span className="text-[10px] text-slate-400 uppercase">Azonnali jóváírás</span>
                  </button>
                  <button className="p-6 border border-slate-100 rounded-2xl flex flex-col items-center gap-3 hover:bg-slate-50 transition-all group">
                    <ICONS.Landmark size={32} className="text-slate-400 group-hover:text-primary transition-all" />
                    <span className="font-bold text-slate-800">Banki Átutalás</span>
                    <span className="text-[10px] text-slate-400 uppercase">2-3 munkanap</span>
                  </button>
                </div>
              )}
            </div>
          </div>

          <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
            <h3 className="text-lg font-bold text-slate-800 mb-6">Tranzakciós Előzmények</h3>
            <div className="space-y-4">
              {payments.length > 0 ? payments.map(payment => (
                <div key={payment.id} className="flex items-center justify-between p-4 border-b border-slate-50 last:border-0">
                  <div className="flex items-center gap-4">
                    <div className={`w-10 h-10 rounded-xl flex items-center justify-center ${payment.status === 'Paid' ? 'bg-emerald-50 text-emerald-600' : 'bg-amber-50 text-amber-600'}`}>
                      <ICONS.Receipt size={20} />
                    </div>
                    <div>
                      <p className="text-sm font-bold text-slate-800">{payment.type}</p>
                      <p className="text-[10px] text-slate-400">{payment.date} • {payment.method}</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className="text-sm font-black text-slate-900">€{payment.amount.toLocaleString()}</p>
                    <p className={`text-[10px] font-bold uppercase ${payment.status === 'Paid' ? 'text-emerald-500' : 'text-amber-500'}`}>{payment.status}</p>
                  </div>
                </div>
              )) : (
                <p className="text-center text-slate-400 py-8 text-sm italic">Még nincsenek tranzakciók.</p>
              )}
            </div>
          </div>
        </div>

        <div className="space-y-6">
          <div className="bg-amber-50 p-6 rounded-3xl border border-amber-100">
            <h4 className="font-bold text-amber-900 mb-4 flex items-center gap-2">
              <ICONS.Info size={18} /> Fontos Tudnivalók
            </h4>
            <ul className="space-y-3 text-xs text-amber-800 leading-relaxed">
              <li>• A jelentkezési díj nem visszatérítendő.</li>
              <li>• Átutalás esetén kérjük tüntesd fel a jelentkezési azonosítódat: <span className="font-bold">{student.id}</span></li>
              <li>• A tandíj befizetése után állítjuk ki a végleges befogadó nyilatkozatot a vízumhoz.</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    );
  };

  const renderInterviews = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {showVideoInterview ? (
        <div className="space-y-6">
          <button 
            onClick={() => setShowVideoInterview(false)}
            className="flex items-center gap-2 text-slate-500 hover:text-slate-800 font-bold text-sm transition-all"
          >
            <ICONS.ArrowLeft size={18} /> Vissza az interjúkhoz
          </button>
          <VideoInterviewSystem onComplete={handleVideoInterviewComplete} />
        </div>
      ) : (
        <>
          {/* Video Interview Section */}
          <div className="bg-indigo-600 p-8 rounded-[32px] text-white shadow-xl shadow-indigo-100 flex flex-col md:flex-row items-center justify-between gap-8">
            <div className="space-y-4 max-w-xl">
              <div className="w-12 h-12 bg-white/20 rounded-2xl flex items-center justify-center">
                <ICONS.Video size={24} />
              </div>
              <h3 className="text-2xl font-bold">Automata Videó Interjú</h3>
              <p className="text-indigo-100 text-sm leading-relaxed">
                Ez egy kötelező lépés a felvételi folyamatban. Válaszoljon 4 előre rögzített kérdésre videón keresztül. 
                A válaszokat a felvételi bizottság fogja értékelni.
              </p>
              <div className="flex items-center gap-4 text-xs font-bold">
                <div className="flex items-center gap-1.5">
                  <ICONS.Clock size={14} /> ~10 perc
                </div>
                <div className="flex items-center gap-1.5">
                  <ICONS.CheckCircle size={14} /> 4 kérdés
                </div>
              </div>
            </div>
            <button 
              onClick={() => setShowVideoInterview(true)}
              className="bg-white text-indigo-600 px-8 py-4 rounded-2xl font-bold hover:bg-indigo-50 transition-all shadow-lg whitespace-nowrap"
            >
              Interjú megkezdése
            </button>
          </div>

          <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
            <h3 className="text-xl font-bold text-slate-800 mb-2">Személyes Interjú Időpont Foglalás</h3>
            <p className="text-sm text-slate-500 mb-8">Válassz egy számodra megfelelő időpontot a felvételi beszélgetéshez (Teams/Zoom).</p>
            
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {interviewSlots.filter(s => s.status === 'Available').map((slot) => (
                <div key={slot.id} className="p-6 border border-slate-100 rounded-2xl hover:border-primary/30 transition-all group">
                  <div className="flex items-center gap-3 mb-4">
                    <div className="w-10 h-10 bg-slate-50 text-slate-400 group-hover:bg-primary/10 group-hover:text-primary rounded-xl flex items-center justify-center transition-all">
                      <ICONS.Calendar size={20} />
                    </div>
                    <div>
                      <p className="text-sm font-bold text-slate-800">{new Date(slot.startTime).toLocaleDateString('hu-HU', { month: 'long', day: 'numeric' })}</p>
                      <p className="text-[10px] text-slate-400">{new Date(slot.startTime).toLocaleTimeString('hu-HU', { hour: '2-digit', minute: '2-digit' })} - {new Date(slot.endTime).toLocaleTimeString('hu-HU', { hour: '2-digit', minute: '2-digit' })}</p>
                    </div>
                  </div>
                  <p className="text-[10px] text-slate-400 font-bold uppercase mb-4">Vizsgáztató: {slot.interviewerName}</p>
                  <button 
                    onClick={() => handleBookInterview(slot.id)}
                    className="w-full py-2 bg-slate-50 text-slate-600 group-hover:bg-primary group-hover:text-white rounded-xl text-xs font-bold transition-all"
                  >
                    Foglalás
                  </button>
                </div>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  );

  const renderMessages = () => {
    const SD = JourneyShared.STEP_DEFS || [];
    const sorted = [...messages].sort((a, b) => (a.read === b.read) ? 0 : (a.read ? 1 : -1));
    const procOf = (id) => journeyProcs.find(p => p.id === id);
    return (
      <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden">
          <div className="p-6 border-b border-slate-50 flex justify-between items-center gap-4">
            <div>
              <h3 className="text-xl font-bold text-slate-800">Üzenetek {unreadCount > 0 && <span className="ml-1 text-sm font-bold text-primary">({unreadCount} új)</span>}</h3>
              <p className="text-xs text-slate-400 mt-0.5">Felvételi folyamatokhoz kapcsolódó értesítések</p>
            </div>
            {unreadCount > 0 && <button onClick={markAllRead} className="text-xs font-bold text-primary hover:underline whitespace-nowrap">Összes megjelölése olvasottként</button>}
          </div>
          <div className="divide-y divide-slate-50">
            {sorted.length === 0 && <div className="p-10 text-center text-slate-400 text-sm">Nincs üzenet.</div>}
            {sorted.map(m => {
              const proc = m.processId ? procOf(m.processId) : null;
              const stLabel = proc ? (proc.done ? 'Felvéve' : (SD[proc.step] ? SD[proc.step].label : '—')) : null;
              return (
                <div key={m.id} onClick={() => markRead(m.id)} className={`p-6 hover:bg-slate-50 transition-colors cursor-pointer flex items-start gap-4 ${!m.read ? 'bg-primary/5' : ''}`}>
                  <div className={`w-10 h-10 rounded-xl flex items-center justify-center shrink-0 ${m.tone === 'success' ? 'bg-emerald-50 text-emerald-600' : m.tone === 'warning' ? 'bg-amber-50 text-amber-600' : m.tone === 'action' ? 'bg-primary/10 text-primary' : 'bg-slate-100 text-slate-400'}`}><Lucide.Mail size={18} /></div>
                  <div className="flex-1 min-w-0">
                    <div className="flex justify-between items-start mb-1 gap-3">
                      <div className="flex items-center gap-2 flex-wrap">
                        <h5 className={`text-sm ${!m.read ? 'font-bold text-slate-900' : 'text-slate-600'}`}>{/Rendszer|System/.test(m.sender||'') ? m.sender : 'Külügyi Iroda'}</h5>
                        {m.applicant && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 inline-flex items-center gap-1"><Lucide.User size={10} /> {m.applicant}</span>}
                        {stLabel && <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-primary/10 text-primary">{stLabel}</span>}
                      </div>
                      <span className="text-[10px] text-slate-400 shrink-0">{m.date}</span>
                    </div>
                    <p className={`text-sm ${!m.read ? 'font-bold text-slate-800' : 'text-slate-500'}`}>{m.subject}</p>
                    <p className="text-xs text-slate-400 mt-1">{m.preview}</p>
                    {m.attachments && m.attachments.length > 0 && <div className="flex flex-wrap gap-1.5 mt-2">{m.attachments.map(a => <span key={a.id} className="text-[10px] font-bold px-2 py-1 rounded-full bg-slate-100 text-slate-600 inline-flex items-center gap-1"><Lucide.Paperclip size={10} /> {a.label}</span>)}</div>}
                  </div>
                  {!m.read && <div className="w-2 h-2 bg-primary rounded-full mt-2 shrink-0"></div>}
                </div>
              );
            })}
          </div>
        </div>
      </div>
    );
  };

  const renderProfile = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
        <div className="flex items-center gap-8 mb-12">
          <div className="relative">
            <div className="w-24 h-24 bg-slate-100 rounded-3xl flex items-center justify-center text-slate-400 text-3xl font-black">
              {user.name.charAt(0)}
            </div>
            <button className="absolute -bottom-2 -right-2 w-8 h-8 bg-primary text-white rounded-xl flex items-center justify-center shadow-lg">
              <ICONS.Camera size={16} />
            </button>
          </div>
          <div>
            <h3 className="text-2xl font-black text-slate-800">{user.name}</h3>
            <p className="text-slate-500">{user.email}</p>
            <div className="flex gap-2 mt-3">
              <span className="px-3 py-1 bg-slate-100 text-slate-600 rounded-lg text-[10px] font-bold uppercase tracking-wider">Hallgató</span>
              <span className="px-3 py-1 bg-emerald-50 text-emerald-600 rounded-lg text-[10px] font-bold uppercase tracking-wider">Aktív Jelentkezés</span>
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
          <div className="space-y-4">
            <label className="text-xs font-bold text-slate-400 uppercase tracking-widest block">Teljes Név</label>
            <input 
              type="text" 
              defaultValue={user.name}
              className="w-full px-5 py-3 bg-slate-50 border border-slate-100 rounded-xl text-sm focus:outline-none focus:border-primary/30 transition-all"
            />
          </div>
          <div className="space-y-4">
            <label className="text-xs font-bold text-slate-400 uppercase tracking-widest block">E-mail Cím</label>
            <input 
              type="email" 
              defaultValue={user.email}
              disabled
              className="w-full px-5 py-3 bg-slate-50 border border-slate-100 rounded-xl text-sm opacity-60 cursor-not-allowed"
            />
          </div>
          <div className="space-y-4">
            <label className="text-xs font-bold text-slate-400 uppercase tracking-widest block">Telefonszám</label>
            <input 
              type="tel" 
              placeholder="+36 30 123 4567"
              className="w-full px-5 py-3 bg-slate-50 border border-slate-100 rounded-xl text-sm focus:outline-none focus:border-primary/30 transition-all"
            />
          </div>
          <div className="space-y-4">
            <label className="text-xs font-bold text-slate-400 uppercase tracking-widest block">Lakcím</label>
            <input 
              type="text" 
              placeholder="Város, Utca, Házszám"
              className="w-full px-5 py-3 bg-slate-50 border border-slate-100 rounded-xl text-sm focus:outline-none focus:border-primary/30 transition-all"
            />
          </div>
        </div>

        <div className="mt-12 pt-8 border-t border-slate-50 flex justify-end gap-4">
          <button className="px-6 py-3 text-sm font-bold text-slate-400 hover:text-slate-600 transition-all">Mégse</button>
          <button className="px-8 py-3 bg-primary text-white rounded-xl text-sm font-bold shadow-lg shadow-primary/20 hover:bg-primary/90 transition-all">
            Változtatások Mentése
          </button>
        </div>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Hallgatói Portál</h2>
          <p className="text-slate-500 mt-1">Üdvözlünk, {user.name}! Kövesd nyomon a jelentkezésed folyamatát.</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="px-4 py-2 bg-primary/10 text-primary rounded-xl text-xs font-bold uppercase tracking-widest">
            ID: {student.id}
          </div>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveTab('dashboard')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'dashboard' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Áttekintés
        </button>
        <button 
          onClick={() => setActiveTab('journey')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'journey' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Felvételi folyamat
        </button>
        <button 
          onClick={() => setActiveTab('application')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'application' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Jelentkezés
        </button>
        <button 
          onClick={() => setActiveTab('documents')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'documents' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Dokumentumok
        </button>
        <button 
          onClick={() => setActiveTab('recommendations')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'recommendations' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Ajánlólevelek
        </button>
        <button 
          onClick={() => setActiveTab('visa')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'visa' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Vízum
        </button>
        <button 
          onClick={() => setActiveTab('finance')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'finance' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Pénzügyek
        </button>
        <button 
          onClick={() => setActiveTab('interviews')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'interviews' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Interjúk
        </button>
        <button 
          onClick={() => setActiveTab('messages')}
          className={`relative px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'messages' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Üzenetek
          {unreadCount > 0 && <span className="ml-2 inline-flex items-center justify-center min-w-[18px] h-[18px] px-1 rounded-full bg-primary text-white text-[10px] font-black align-middle">{unreadCount}</span>}
        </button>
        <button 
          onClick={() => setActiveTab('profile')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeTab === 'profile' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Profilom
        </button>
      </div>

      {/* Content */}
      <div className="mt-8">
        {activeTab === 'dashboard' && renderDashboard()}
        {activeTab === 'journey' && <AdmissionsHub user={user} />}
        {activeTab === 'application' && renderApplication()}
        {activeTab === 'documents' && renderDocuments()}
        {activeTab === 'recommendations' && renderRecommendations()}
        {activeTab === 'visa' && renderVisa()}
        {activeTab === 'finance' && renderFinance()}
        {activeTab === 'interviews' && renderInterviews()}
        {activeTab === 'messages' && renderMessages()}
        {activeTab === 'profile' && renderProfile()}
      </div>
    </div>
  );
};
return StudentPortal;
})();

/* ===== MarketingLeads ===== */
const MarketingLeads = (() => {
const COLORS = ['#0F172A', '#3B82F6', '#10B981', '#F59E0B', '#EF4444', '#8B5CF6'];

const MarketingLeads: React.FC = () => {
  const [leads, setLeads] = useState<Lead[]>([]);
  const [campaigns, setCampaigns] = useState<MarketingCampaign[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<'overview' | 'leads' | 'campaigns'>('overview');

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [leadsData, campaignsData] = await Promise.all([
          api.getLeads(),
          api.getMarketingCampaigns()
        ]);
        setLeads(leadsData);
        setCampaigns(campaignsData);
      } catch (error) {
        console.error('Failed to fetch marketing data:', error);
      } finally {
        setIsLoading(false);
      }
    };
    fetchData();
  }, []);

  const getSourceData = () => {
    const sources: Record<string, number> = {};
    leads.forEach(lead => {
      sources[lead.source] = (sources[lead.source] || 0) + 1;
    });
    return Object.entries(sources).map(([name, value]) => ({ name, value }));
  };

  const getStatusData = () => {
    const statuses: Record<string, number> = {};
    leads.forEach(lead => {
      statuses[lead.status] = (statuses[lead.status] || 0) + 1;
    });
    return Object.entries(statuses).map(([name, value]) => ({ name, value }));
  };

  const getCampaignPerformance = () => {
    return campaigns.map(c => ({
      name: c.name,
      leads: c.leadsGenerated,
      conversions: c.conversions,
      roi: ((c.conversions * 5000) / c.spent).toFixed(1) // Mock ROI calculation
    }));
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-96">
        <div className="w-10 h-10 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
      </div>
    );
  }

  const renderOverview = () => (
    <div className="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {[
          { label: 'Összes Lead', value: leads.length, icon: <ICONS.Users />, color: 'bg-blue-50 text-blue-600' },
          { label: 'Konverziós Arány', value: `${((leads.filter(l => l.status === 'Converted').length / leads.length) * 100).toFixed(1)}%`, icon: <ICONS.Target />, color: 'bg-emerald-50 text-emerald-600' },
          { label: 'Aktív Kampányok', value: campaigns.filter(c => c.status === 'Active').length, icon: <ICONS.Zap />, color: 'bg-amber-50 text-amber-600' },
          { label: 'Marketing Költségkeret', value: `€${campaigns.reduce((acc, c) => acc + c.budget, 0).toLocaleString()}`, icon: <ICONS.CreditCard />, color: 'bg-slate-50 text-slate-600' },
        ].map((stat, i) => (
          <motion.div 
            key={i}
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: i * 0.1 }}
            className="bg-white p-6 rounded-3xl border border-slate-100 shadow-sm"
          >
            <div className={`w-12 h-12 ${stat.color} rounded-2xl flex items-center justify-center mb-4`}>
              {stat.icon}
            </div>
            <p className="text-slate-400 text-xs font-bold uppercase tracking-widest mb-1">{stat.label}</p>
            <h3 className="text-2xl font-black text-slate-900">{stat.value}</h3>
          </motion.div>
        ))}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
        {/* Source Analysis */}
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <h4 className="font-bold text-slate-800 mb-6">Lead Források Eloszlása</h4>
          <div className="h-80">
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={getSourceData()}
                  cx="50%"
                  cy="50%"
                  innerRadius={60}
                  outerRadius={100}
                  paddingAngle={5}
                  dataKey="value"
                >
                  {getSourceData().map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={COLORS[index % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* Campaign Performance */}
        <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
          <h4 className="font-bold text-slate-800 mb-6">Kampány Teljesítmény (Lead vs Konverzió)</h4>
          <div className="h-80">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={getCampaignPerformance()}>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#f1f5f9" />
                <XAxis dataKey="name" axisLine={false} tickLine={false} tick={{ fontSize: 10, fill: '#94a3b8' }} />
                <YAxis axisLine={false} tickLine={false} tick={{ fontSize: 10, fill: '#94a3b8' }} />
                <Tooltip 
                  contentStyle={{ borderRadius: '16px', border: 'none', boxShadow: '0 10px 15px -3px rgb(0 0 0 / 0.1)' }}
                />
                <Legend />
                <Bar dataKey="leads" fill="#3B82F6" radius={[4, 4, 0, 0]} name="Leadek" />
                <Bar dataKey="conversions" fill="#10B981" radius={[4, 4, 0, 0]} name="Konverziók" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>
    </div>
  );

  const renderLeads = () => (
    <div className="bg-white rounded-3xl border border-slate-100 shadow-sm overflow-hidden animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="p-8 border-b border-slate-50 flex items-center justify-between">
        <h3 className="text-xl font-bold text-slate-800">Lead Adatbázis</h3>
        <div className="flex gap-2">
          <button className="p-2 text-slate-400 hover:text-primary transition-colors">
            <ICONS.Search size={20} />
          </button>
          <button className="p-2 text-slate-400 hover:text-primary transition-colors">
            <ICONS.Filter size={20} />
          </button>
          <button className="bg-slate-900 text-white px-4 py-2 rounded-xl text-xs font-bold hover:bg-black transition-all">
            Új Lead Hozzáadása
          </button>
        </div>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full text-left">
          <thead>
            <tr className="bg-slate-50/50">
              <th className="px-8 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Név / Kapcsolat</th>
              <th className="px-8 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Forrás / UTM</th>
              <th className="px-8 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Státusz</th>
              <th className="px-8 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest">Dátum</th>
              <th className="px-8 py-4 text-[10px] font-bold text-slate-400 uppercase tracking-widest"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-50">
            {leads.map((lead) => (
              <tr key={lead.id} className="hover:bg-slate-50/50 transition-colors group">
                <td className="px-8 py-4">
                  <div>
                    <p className="font-bold text-slate-800 text-sm">{lead.name}</p>
                    <p className="text-[10px] text-slate-400">{lead.email}</p>
                  </div>
                </td>
                <td className="px-8 py-4">
                  <div>
                    <span className="px-2 py-1 bg-slate-100 text-slate-600 rounded text-[10px] font-bold uppercase">{lead.source}</span>
                    {lead.utmCampaign && (
                      <p className="text-[10px] text-slate-400 mt-1">Campaign: {lead.utmCampaign}</p>
                    )}
                  </div>
                </td>
                <td className="px-8 py-4">
                  <span className={`px-3 py-1 rounded-full text-[10px] font-bold uppercase ${
                    lead.status === 'Converted' ? 'bg-emerald-100 text-emerald-700' :
                    lead.status === 'New' ? 'bg-blue-100 text-blue-700' :
                    lead.status === 'Lost' ? 'bg-red-100 text-red-700' : 'bg-amber-100 text-amber-700'
                  }`}>
                    {lead.status}
                  </span>
                </td>
                <td className="px-8 py-4 text-xs text-slate-500">{lead.createdAt}</td>
                <td className="px-8 py-4 text-right">
                  <button className="text-slate-300 group-hover:text-primary transition-colors">
                    <ICONS.MoreHorizontal size={20} />
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );

  const renderCampaigns = () => (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      {campaigns.map((campaign) => (
        <div key={campaign.id} className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm hover:border-primary/20 transition-all group">
          <div className="flex items-center justify-between mb-6">
            <div className={`w-12 h-12 rounded-2xl flex items-center justify-center ${
              campaign.platform === 'Google Ads' ? 'bg-blue-50 text-blue-600' :
              campaign.platform === 'Facebook' ? 'bg-indigo-50 text-indigo-600' : 'bg-slate-50 text-slate-600'
            }`}>
              {campaign.platform === 'Google Ads' ? <ICONS.Search size={24} /> : <ICONS.Share2 size={24} />}
            </div>
            <span className={`px-3 py-1 rounded-full text-[10px] font-bold uppercase ${
              campaign.status === 'Active' ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-100 text-slate-500'
            }`}>
              {campaign.status}
            </span>
          </div>
          <h4 className="font-bold text-slate-800 mb-1">{campaign.name}</h4>
          <p className="text-xs text-slate-400 mb-6">{campaign.platform} • Kezdés: {campaign.startDate}</p>
          
          <div className="grid grid-cols-2 gap-4 mb-6">
            <div className="p-3 bg-slate-50 rounded-xl">
              <p className="text-[10px] font-bold text-slate-400 uppercase mb-1">Költés</p>
              <p className="text-sm font-black text-slate-800">€{campaign.spent.toLocaleString()}</p>
            </div>
            <div className="p-3 bg-slate-50 rounded-xl">
              <p className="text-[10px] font-bold text-slate-400 uppercase mb-1">Leadek</p>
              <p className="text-sm font-black text-slate-800">{campaign.leadsGenerated}</p>
            </div>
          </div>

          <div className="space-y-2">
            <div className="flex justify-between text-[10px] font-bold text-slate-400 uppercase">
              <span>Költségkeret Felhasználás</span>
              <span>{Math.round((campaign.spent / campaign.budget) * 100)}%</span>
            </div>
            <div className="w-full h-1.5 bg-slate-100 rounded-full overflow-hidden">
              <div 
                className="h-full bg-primary transition-all duration-1000" 
                style={{ width: `${(campaign.spent / campaign.budget) * 100}%` }}
              />
            </div>
          </div>
        </div>
      ))}
      <button className="border-2 border-dashed border-slate-200 rounded-3xl p-8 flex flex-col items-center justify-center gap-4 text-slate-400 hover:border-primary/30 hover:text-primary transition-all group">
        <div className="w-12 h-12 rounded-full border-2 border-dashed border-slate-200 group-hover:border-primary/30 flex items-center justify-center">
          <ICONS.Plus size={24} />
        </div>
        <span className="font-bold text-sm">Új Kampány Indítása</span>
      </button>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Marketing & Lead Kezelés</h2>
          <p className="text-slate-500 mt-1">Kampány teljesítmény és lead konverzió elemzése.</p>
        </div>
        <div className="flex items-center gap-3">
          <button className="px-6 py-3 bg-white border border-slate-200 rounded-2xl text-sm font-bold text-slate-700 hover:bg-slate-50 transition-all flex items-center gap-2 shadow-sm">
            <ICONS.Download size={18} /> Exportálás
          </button>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm">
        <button 
          onClick={() => setActiveTab('overview')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all ${activeTab === 'overview' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Áttekintés
        </button>
        <button 
          onClick={() => setActiveTab('leads')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all ${activeTab === 'leads' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Lead Adatbázis
        </button>
        <button 
          onClick={() => setActiveTab('campaigns')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all ${activeTab === 'campaigns' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Kampányok
        </button>
      </div>

      {/* Content */}
      <div className="mt-8">
        {activeTab === 'overview' && renderOverview()}
        {activeTab === 'leads' && renderLeads()}
        {activeTab === 'campaigns' && renderCampaigns()}
      </div>
    </div>
  );
};
return MarketingLeads;
})();

/* ===== Reports ===== */
const Reports = (() => {
type ReportType = 'ApplicantRegistrations' | 'ApplicationLastRevised' | 'ApplicationRevisions' | 'DocumentUploads' | 'Status' | 'StatusByCitizenship' | 'StatusByInstitutionAll' | 'StatusByInstitutionTop1' | 'StatusByInstitutionTop3' | 'SizeByStatus' | 'Invoices' | 'StatusByCourseAdmin' | 'StatusByCourseApplicant' | 'StatusByCitizenshipAdmin' | 'StatusByCitizenshipApplicant' | 'ApplicationsMatrix' | 'OffersMatrix' | 'ApplicationsFunnelMonthly' | 'ApplicationsFunnelWeekly' | 'ApplicationsPriorities' | 'InvoicesDetails';

const Reports: React.FC = () => {
  const [selectedReport, setSelectedReport] = useState<ReportType | null>(null);

  const reports = [
    { id: 'ApplicantRegistrations', name: 'ApplicantRegistrations', description: 'How many applicants registered on a particular date?' },
    { id: 'ApplicationLastRevised', name: 'ApplicationLastRevised', description: 'Shows how many applications were *last revised* (changed one or more times) on a particular date.' },
    { id: 'ApplicationRevisions', name: 'ApplicationRevisions', description: 'Shows how many revisions altogether there were on a particular date.' },
    { id: 'DocumentUploads', name: 'DocumentUploads', description: 'Shows the document uploading activity - an indicator of applicants working with the applications.' },
    { id: 'Status', name: 'Status', description: 'A quick overview of the aggregate numbers of applications in a particular status.' },
    { id: 'StatusByCitizenship', name: 'StatusByCitizenship', description: 'A quick overview of the aggregate numbers of applications in a particular status, with more detailed info per citizenships.' },
    { id: 'StatusByInstitutionAll', name: 'StatusByInstitutionAll', description: 'Shows how many applications and in which statuses have courses from a particular institution. Please note that this report takes into account all priorities.' },
    { id: 'StatusByInstitutionTop1', name: 'StatusByInstitutionTop1', description: 'Shows how many applications and in which statuses have courses from a particular institution, counting the applications only if a particular institution was selected as the 1st priority.' },
    { id: 'StatusByInstitutionTop3', name: 'StatusByInstitutionTop3', description: 'Shows how many applications and in which statuses have courses from a particular institution, counting the applications only if a particular institution was selected as a TOP 3 priority.' },
    { id: 'SizeByStatus', name: 'SizeByStatus', description: 'Shows the distribution (histogram) of application sizes as a way of measuring applicants progress with their applications.' },
    { id: 'Invoices', name: 'Invoices', description: 'Overview of invoiced amounts, collections and overdues.' },
    { id: 'StatusByCourseAdmin', name: 'StatusByCourseAdmin', description: 'Overview on admin statuses per course' },
    { id: 'StatusByCourseApplicant', name: 'StatusByCourseApplicant', description: 'Overview on applicant statuses per course' },
    { id: 'StatusByCitizenshipAdmin', name: 'StatusByCitizenshipAdmin', description: 'Overview on admin statuses per citizenship' },
    { id: 'StatusByCitizenshipApplicant', name: 'StatusByCitizenshipApplicant', description: 'Overview on applicant statuses per citizenship' },
    { id: 'ApplicationsMatrix', name: 'ApplicationsMatrix', description: 'Shows a matrix of application statuses and citizenships with both totals' },
    { id: 'OffersMatrix', name: 'OffersMatrix', description: 'Shows a matrix of offer types and citizenships with both totals' },
    { id: 'ApplicationsFunnelMonthly', name: 'ApplicationsFunnelMonthly', description: 'Compares application statistics between two years on a monthly basis.' },
    { id: 'ApplicationsFunnelWeekly', name: 'ApplicationsFunnelWeekly', description: 'Compares application statistics between two years on a weekly basis.' },
    { id: 'ApplicationsPriorities', name: 'ApplicationsPriorities', description: 'Shows the relative priorities of applicants among several institutions. Useful only in a collaborative use case among several institutions.' },
    { id: 'InvoicesDetails', name: 'InvoicesDetails', description: 'Detailed report of issued invoices.' },
  ];

  const renderReportContent = () => {
    switch (selectedReport) {
      case 'ApplicantRegistrations':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2026</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Date</th>
                    <th className="px-6 py-4">Registered</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { date: '2026-03-05', count: 9 },
                    { date: '2026-03-04', count: 15 },
                    { date: '2026-03-03', count: 24 },
                    { date: '2026-03-02', count: 17 },
                    { date: '2026-03-01', count: 20 },
                    { date: '2026-02-28', count: 15 },
                    { date: '2026-02-27', count: 20 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.date}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'ApplicationLastRevised':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Date</th>
                    <th className="px-6 py-4">Num. last revised</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { date: '2026-03-03', count: 1 },
                    { date: '2026-03-02', count: 1 },
                    { date: '2026-02-25', count: 1 },
                    { date: '2026-02-19', count: 1 },
                    { date: '2026-02-17', count: 1 },
                    { date: '2026-02-04', count: 1 },
                    { date: '2026-01-23', count: 1 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.date}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'ApplicationRevisions':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Date</th>
                    <th className="px-6 py-4">Revisions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { date: '2026-03-03', count: 1 },
                    { date: '2026-03-02', count: 1 },
                    { date: '2026-02-25', count: 1 },
                    { date: '2026-02-19', count: 1 },
                    { date: '2026-02-17', count: 1 },
                    { date: '2026-02-16', count: 1 },
                    { date: '2026-02-04', count: 1 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.date}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'DocumentUploads':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2026</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Date</th>
                    <th className="px-6 py-4">Uploads</th>
                    <th className="px-6 py-4">Uploaders</th>
                    <th className="px-6 py-4">Uploaded</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { date: '2026-03-05', uploads: 139, uploaders: 15, size: '39 MiB' },
                    { date: '2026-03-04', uploads: 112, uploaders: 13, size: '34 MiB' },
                    { date: '2026-03-03', uploads: 191, uploaders: 19, size: '86 MiB' },
                    { date: '2026-03-02', uploads: 135, uploaders: 15, size: '51 MiB' },
                    { date: '2026-03-01', uploads: 192, uploaders: 23, size: '64 MiB' },
                    { date: '2026-02-28', uploads: 161, uploaders: 18, size: '73 MiB' },
                    { date: '2026-02-27', uploads: 110, uploaders: 12, size: '75 MiB' },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.date}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.uploads}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.uploaders}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.size}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'Status':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Status</th>
                    <th className="px-6 py-4">Applications</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { status: 'Blank', count: 289 },
                    { status: 'Inactive', count: 836 },
                    { status: 'Submitted', count: 2685 },
                    { status: 'Reopened', count: 90 },
                    { status: 'Withdrawn', count: 61 },
                    { status: 'Closed', count: 23 },
                    { status: 'ALL STATUSES', count: 3984, isTotal: true },
                  ].map((row, i) => (
                    <tr key={i} className={`hover:bg-slate-50 transition-colors ${row.isTotal ? 'bg-slate-50 font-bold' : ''}`}>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.status}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'StatusByCitizenship':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Status</th>
                    <th className="px-6 py-4">Citizenships</th>
                    <th className="px-6 py-4">Applications</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { status: 'Withdrawn', citizenship: 'ALL CITIZENSHIPS', count: 61, isTotal: true },
                    { status: '', citizenship: 'AF Afghanistan', count: 2 },
                    { status: '', citizenship: 'BD Bangladesh', count: 50 },
                    { status: '', citizenship: 'LR Liberia', count: 1 },
                    { status: '', citizenship: 'MA Morocco', count: 1 },
                    { status: '', citizenship: 'NG Nigeria', count: 1 },
                    { status: '', citizenship: 'PK Pakistan', count: 5 },
                  ].map((row, i) => (
                    <tr key={i} className={`hover:bg-slate-50 transition-colors ${row.isTotal ? 'bg-slate-50 font-bold' : ''}`}>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.status}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.citizenship}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'StatusByInstitutionAll':
      case 'StatusByInstitutionTop1':
      case 'StatusByInstitutionTop3':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Institution</th>
                    <th className="px-6 py-4">Blank</th>
                    <th className="px-6 py-4">Draft</th>
                    <th className="px-6 py-4">Inactive</th>
                    <th className="px-6 py-4">Reopened</th>
                    <th className="px-6 py-4">Submitted</th>
                    <th className="px-6 py-4">Withdrawn</th>
                    <th className="px-6 py-4">Closed</th>
                    <th className="px-6 py-4">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  <tr className="hover:bg-slate-50 transition-colors">
                    <td className="px-6 py-4 text-sm text-slate-600 font-medium">HU, John von Neumann University</td>
                    <td className="px-6 py-4 text-sm text-slate-600">289</td>
                    <td className="px-6 py-4 text-sm text-slate-600">0</td>
                    <td className="px-6 py-4 text-sm text-slate-600">836</td>
                    <td className="px-6 py-4 text-sm text-slate-600">90</td>
                    <td className="px-6 py-4 text-sm text-slate-600">2685</td>
                    <td className="px-6 py-4 text-sm text-slate-600">61</td>
                    <td className="px-6 py-4 text-sm text-slate-600">23</td>
                    <td className="px-6 py-4 text-sm text-slate-600 font-bold">3984</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p className="text-[10px] text-slate-400 italic">Data in this table is delayed by up to 15 minutes</p>
          </div>
        );
      case 'SizeByStatus':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[800px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Status</th>
                    <th className="px-6 py-4">Total</th>
                    <th className="px-6 py-4">..-5</th>
                    <th className="px-6 py-4">5-10</th>
                    <th className="px-6 py-4">10-15</th>
                    <th className="px-6 py-4">15-20</th>
                    <th className="px-6 py-4">20-25</th>
                    <th className="px-6 py-4">25-30</th>
                    <th className="px-6 py-4">30-35</th>
                    <th className="px-6 py-4">35-40</th>
                    <th className="px-6 py-4">40-..</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { status: 'Submitted', total: 2685, c1: 0, c2: 109, c3: 131, c4: 443, c5: 1429, c6: 481, c7: 67, c8: 17, c9: 8 },
                    { status: 'Reopened', total: 97, c1: 3, c2: 5, c3: 7, c4: 20, c5: 42, c6: 17, c7: 3, c8: 0, c9: 0 },
                    { status: 'Inactive', total: 861, c1: 419, c2: 251, c3: 67, c4: 27, c5: 66, c6: 26, c7: 5, c8: 0, c9: 0 },
                    { status: 'Blank', total: 289, c1: 289, c2: 0, c3: 0, c4: 0, c5: 0, c6: 0, c7: 0, c8: 0, c9: 0 },
                    { status: 'Withdrawn', total: 73, c1: 0, c2: 3, c3: 3, c4: 7, c5: 48, c6: 10, c7: 2, c8: 0, c9: 0 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600 font-medium">{row.status}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.total}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c1}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c2}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c3}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c4}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c5}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c6}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c7}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c8}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.c9}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-[10px] text-slate-400 italic">Data in this table is delayed by up to 33 minutes</p>
          </div>
        );
      case 'ApplicationsMatrix':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1000px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Citizenship</th>
                    <th className="px-6 py-4">Blank</th>
                    <th className="px-6 py-4">Draft</th>
                    <th className="px-6 py-4">Inactive</th>
                    <th className="px-6 py-4">Reopened</th>
                    <th className="px-6 py-4">Submitted</th>
                    <th className="px-6 py-4">Withdrawn</th>
                    <th className="px-6 py-4">Closed</th>
                    <th className="px-6 py-4 font-bold">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { cit: 'AE United Arab Emirates', bl: 4, dr: 0, in: 2, re: 0, sub: 7, with: 0, cl: 0, tot: 13 },
                    { cit: 'AF Afghanistan', bl: 3, dr: 0, in: 15, re: 4, sub: 111, with: 2, cl: 0, tot: 135 },
                    { cit: 'AO Angola', bl: 0, dr: 0, in: 5, re: 0, sub: 0, with: 0, cl: 0, tot: 5 },
                    { cit: 'AU Australia', bl: 0, dr: 0, in: 1, re: 0, sub: 0, with: 0, cl: 0, tot: 1 },
                    { cit: 'AZ Azerbaijan', bl: 1, dr: 0, in: 2, re: 3, sub: 11, with: 0, cl: 0, tot: 17 },
                    { cit: 'BD Bangladesh', bl: 143, dr: 0, in: 449, re: 57, sub: 1840, with: 50, cl: 19, tot: 2558 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cit}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.bl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.dr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.in}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.re}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.sub}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.with}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'OffersMatrix':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1000px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Citizenship</th>
                    <th className="px-6 py-4">Unreplied</th>
                    <th className="px-6 py-4">Nominated</th>
                    <th className="px-6 py-4">Conditionally accepted</th>
                    <th className="px-6 py-4">Accepted</th>
                    <th className="px-6 py-4">Visa</th>
                    <th className="px-6 py-4">Failed</th>
                    <th className="px-6 py-4">Arrived</th>
                    <th className="px-6 py-4">Refused</th>
                    <th className="px-6 py-4 font-bold">TOTAL</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { cit: 'AE United Arab Emirates', un: 0, nom: 0, cond: 1, acc: 1, visa: 0, fail: 0, arr: 0, ref: 7, tot: 9 },
                    { cit: 'AF Afghanistan', un: 1, nom: 6, cond: 17, acc: 40, visa: 0, fail: 8, arr: 0, ref: 51, tot: 123 },
                    { cit: 'AZ Azerbaijan', un: 0, nom: 0, cond: 6, acc: 3, visa: 0, fail: 0, arr: 0, ref: 7, tot: 16 },
                    { cit: 'BD Bangladesh', un: 133, nom: 78, cond: 180, acc: 219, visa: 0, fail: 202, arr: 0, ref: 1307, tot: 2119 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cit}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.un}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.nom}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cond}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.acc}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.visa}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.fail}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.arr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.ref}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'ApplicationsFunnelMonthly':
      case 'ApplicationsFunnelWeekly':
        const isWeekly = selectedReport === 'ApplicationsFunnelWeekly';
        const funnelData = isWeekly 
          ? Array.from({ length: 53 }, (_, i) => ({
              name: `# ${i + 1}`,
              v1: Math.random() * 100 + (i > 35 ? Math.sin(i / 2) * 100 + 100 : 0),
              v2: Math.random() * 80 + (i > 35 ? Math.cos(i / 2) * 80 + 80 : 0),
              v3: Math.random() * 50 + (i > 35 ? Math.sin(i / 3) * 50 + 50 : 0),
            }))
          : [
              { name: 'January', v1: 100, v2: 80, v3: 50 },
              { name: 'February', v1: 120, v2: 90, v3: 60 },
              { name: 'March', v1: 150, v2: 110, v3: 70 },
              { name: 'April', v1: 180, v2: 130, v3: 80 },
              { name: 'May', v1: 200, v2: 150, v3: 90 },
              { name: 'June', v1: 220, v2: 170, v3: 100 },
              { name: 'July', v1: 250, v2: 190, v3: 110 },
              { name: 'August', v1: 300, v2: 220, v3: 130 },
              { name: 'September', v1: 600, v2: 500, v3: 200 },
              { name: 'October', v1: 650, v2: 550, v3: 250 },
              { name: 'November', v1: 400, v2: 300, v3: 150 },
              { name: 'December', v1: 200, v2: 150, v3: 100 },
            ];
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>Spring semester</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            
            <div className="bg-white p-8 rounded-xl border border-slate-100">
              <h3 className="text-center text-slate-600 font-medium mb-8">Term: Spring semester</h3>
              <div className="h-[400px] w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={funnelData}>
                    <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#f1f5f9" />
                    <XAxis 
                      dataKey="name" 
                      axisLine={false} 
                      tickLine={false} 
                      tick={{ fontSize: 10, fill: '#94a3b8' }}
                      interval={isWeekly ? 4 : 0}
                    />
                    <YAxis 
                      axisLine={false} 
                      tickLine={false} 
                      tick={{ fontSize: 10, fill: '#94a3b8' }}
                    />
                    <Tooltip />
                    <Line type="monotone" dataKey="v1" stroke="#fbbf24" strokeWidth={3} dot={false} />
                    <Line type="monotone" dataKey="v2" stroke="#a3e635" strokeWidth={3} dot={false} />
                    <Line type="monotone" dataKey="v3" stroke="#818cf8" strokeWidth={3} dot={false} />
                  </LineChart>
                </ResponsiveContainer>
              </div>
            </div>

            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden">
              <table className="w-full text-left">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">{isWeekly ? 'Week' : 'Month'}</th>
                    <th className="px-6 py-4">Aggregate</th>
                    <th className="px-6 py-4">Term: Spring semester</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  <tr className="hover:bg-slate-50 transition-colors">
                    <td className="px-6 py-4 text-sm text-slate-600">{isWeekly ? '# 1' : 'January'}</td>
                    <td className="px-6 py-4 text-sm text-slate-600">Enrolments</td>
                    <td className="px-6 py-4 text-sm text-slate-600">0</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'ApplicationsPriorities':
        const priorityData = [
          { name: '1st', value: 1600, color: '#60a5fa' },
          { name: '2nd', value: 0, color: '#94a3b8' },
          { name: '3rd', value: 0, color: '#94a3b8' },
          { name: 'low', value: 0, color: '#94a3b8' },
        ];
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>Spring semester</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
              <div className="text-sm text-slate-500 space-y-4 leading-relaxed">
                <p>This report shows how the applicants prioritized the programmes that you have selected above. This helps you determine which are used as a primary choice for the applicants and which are merely used as 'backups'.</p>
                <p className="font-bold text-slate-700">Especially useful in a collaborative use case among several institutions.</p>
                <p>If there are multiple institutions using the system in a collaborative fashion, this report shows how well you are doing in relation to other institutions.</p>
                <p>For example, if you select only one specific programme from above, you will see how many applicants had it as their 1st priority, 2nd priority and so on.</p>
              </div>
              <div className="bg-white p-8 rounded-xl border border-slate-100">
                <h3 className="text-center text-slate-600 font-medium mb-8">Term: Spring semester</h3>
                <div className="h-[300px] w-full">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={priorityData}>
                      <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#f1f5f9" />
                      <XAxis dataKey="name" axisLine={false} tickLine={false} tick={{ fontSize: 12, fill: '#94a3b8' }} />
                      <YAxis axisLine={false} tickLine={false} tick={{ fontSize: 12, fill: '#94a3b8' }} />
                      <Tooltip cursor={{ fill: '#f8fafc' }} />
                      <Bar dataKey="value" radius={[4, 4, 0, 0]}>
                        {priorityData.map((entry, index) => (
                          <Cell key={`cell-${index}`} fill={entry.color} />
                        ))}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              </div>
            </div>
          </div>
        );
      case 'InvoicesDetails':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1500px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Applicant ID</th>
                    <th className="px-6 py-4">Full name</th>
                    <th className="px-6 py-4">First name</th>
                    <th className="px-6 py-4">Last name</th>
                    <th className="px-6 py-4">Applicant email</th>
                    <th className="px-6 py-4">Application ID</th>
                    <th className="px-6 py-4">Gender</th>
                    <th className="px-6 py-4">Citizenship</th>
                    <th className="px-6 py-4">Nationality</th>
                    <th className="px-6 py-4">Country of residence</th>
                    <th className="px-6 py-4">Date of birth</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { aid: '3914', name: 'Mr Md Borhan Uddin', first: 'Md', last: 'Borhan Uddin', email: 'mdborhanu513@gmail.com', appid: '3983', gen: 'M', cit: 'BD Bangladesh', nat: 'BD Bangladesh', res: '', dob: '2005-04-22' },
                    { aid: '3911', name: 'Kayser', first: '', last: '', email: 'kayserahamed6@gmail.com', appid: '3979', gen: '', cit: 'BD Bangladesh', nat: '', res: '', dob: '' },
                    { aid: '3909', name: 'Mr MD Shajnus Shajnus Chowdhury', first: 'MD', last: 'Shajnus Chowdhury', email: 'shajnuschowdhury90@gmail.com', appid: '3978', gen: 'M', cit: 'BD Bangladesh', nat: 'BD Bangladesh', res: '', dob: '2001-02-25' },
                    { aid: '2067', name: 'Udoy udoy', first: '', last: '', email: 'Udoyu45@gmail.com', appid: '3977', gen: '', cit: 'BD Bangladesh', nat: '', res: '', dob: '' },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.aid}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.name}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.first}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.last}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.email}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.appid}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.gen}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cit}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.nat}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.res}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.dob}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'Invoices':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2026</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white p-12 rounded-xl border border-slate-100 text-center text-slate-400 italic">
              The report contained no data
            </div>
          </div>
        );
      case 'StatusByCourseAdmin':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1200px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Institution</th>
                    <th className="px-6 py-4">Department</th>
                    <th className="px-6 py-4">Awards</th>
                    <th className="px-6 py-4">Course name</th>
                    <th className="px-6 py-4">Unreplied</th>
                    <th className="px-6 py-4">Nominated</th>
                    <th className="px-6 py-4">Conditionally accepted</th>
                    <th className="px-6 py-4">Accepted</th>
                    <th className="px-6 py-4">Visa</th>
                    <th className="px-6 py-4">Failed</th>
                    <th className="px-6 py-4">Arrived</th>
                    <th className="px-6 py-4">Refused</th>
                    <th className="px-6 py-4 font-bold">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { inst: 'John von Neumann University', dept: '> ALL DEPARTMENTS', award: 'PC', course: 'Preparatory English and Math course', un: 0, nom: 9, cond: 34, acc: 49, visa: 0, fail: 45, arr: 0, ref: 110, tot: 247 },
                    { inst: '', dept: 'Faculty of Economics and Business', award: 'BSc', course: 'Tourism and Catering', un: 29, nom: 15, cond: 23, acc: 29, visa: 0, fail: 21, arr: 0, ref: 231, tot: 348 },
                    { inst: '', dept: 'Faculty of Economics and Business', award: 'BSc', course: 'Business Administration and Management', un: 25, nom: 16, cond: 23, acc: 23, visa: 0, fail: 13, arr: 0, ref: 179, tot: 279 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.inst}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.dept}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.award}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.course}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.un}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.nom}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cond}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.acc}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.visa}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.fail}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.arr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.ref}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'StatusByCourseApplicant':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1000px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Institution</th>
                    <th className="px-6 py-4">Awards</th>
                    <th className="px-6 py-4">Course name</th>
                    <th className="px-6 py-4">Blank</th>
                    <th className="px-6 py-4">Draft</th>
                    <th className="px-6 py-4">Inactive</th>
                    <th className="px-6 py-4">Reopened</th>
                    <th className="px-6 py-4">Submitted</th>
                    <th className="px-6 py-4">Withdrawn</th>
                    <th className="px-6 py-4">Closed</th>
                    <th className="px-6 py-4 font-bold">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { inst: 'John von Neumann University', award: 'BSc', course: 'Computer Science Engineering', bl: 58, dr: 0, in: 183, re: 11, sub: 353, with: 8, cl: 0, tot: 613 },
                    { inst: '', award: 'BSc', course: 'Vehicle Engineering', bl: 15, dr: 0, in: 39, re: 0, sub: 55, with: 1, cl: 0, tot: 110 },
                    { inst: '', award: 'BSc', course: 'Horticultural Engineering', bl: 29, dr: 0, in: 99, re: 31, sub: 604, with: 22, cl: 13, tot: 798 },
                    { inst: '', award: 'BSc', course: 'Tourism and Catering', bl: 29, dr: 0, in: 104, re: 10, sub: 336, with: 2, cl: 1, tot: 482 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.inst}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.award}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.course}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.bl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.dr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.in}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.re}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.sub}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.with}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'StatusByCitizenshipAdmin':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1000px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Institution</th>
                    <th className="px-6 py-4">Citizenship</th>
                    <th className="px-6 py-4">Unreplied</th>
                    <th className="px-6 py-4">Nominated</th>
                    <th className="px-6 py-4">Conditionally accepted</th>
                    <th className="px-6 py-4">Accepted</th>
                    <th className="px-6 py-4">Visa</th>
                    <th className="px-6 py-4">Failed</th>
                    <th className="px-6 py-4">Arrived</th>
                    <th className="px-6 py-4">Refused</th>
                    <th className="px-6 py-4 font-bold">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { inst: 'John von Neumann University', cit: 'AE United Arab Emirates', un: 0, nom: 0, cond: 1, acc: 1, visa: 0, fail: 0, arr: 0, ref: 7, tot: 9 },
                    { inst: '', cit: 'AF Afghanistan', un: 1, nom: 6, cond: 17, acc: 40, visa: 0, fail: 7, arr: 0, ref: 49, tot: 120 },
                    { inst: '', cit: 'AZ Azerbaijan', un: 0, nom: 0, cond: 6, acc: 3, visa: 0, fail: 0, arr: 0, ref: 5, tot: 14 },
                    { inst: '', cit: 'BD Bangladesh', un: 128, nom: 77, cond: 180, acc: 219, visa: 0, fail: 197, arr: 0, ref: 1254, tot: 2055 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.inst}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cit}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.un}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.nom}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cond}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.acc}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.visa}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.fail}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.arr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.ref}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      case 'StatusByCitizenshipApplicant':
        return (
          <div className="space-y-6">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-4">
                <div className="flex items-center gap-2 bg-white border border-slate-200 rounded-lg px-3 py-2 text-sm">
                  <ICONS.Calendar size={16} className="text-slate-400" />
                  <span>2025/26 (2/2 terms)</span>
                  <ICONS.ChevronRight size={14} className="rotate-90 text-slate-400" />
                </div>
                <div className="text-slate-400 text-sm italic">Click to add more filters</div>
              </div>
              <div className="flex items-center gap-2">
                <button className="text-sm font-bold text-amber-600 hover:underline">Clear filters</button>
                <button className="flex items-center gap-2 bg-amber-600 text-white px-4 py-2 rounded-lg text-sm font-bold hover:bg-amber-700 transition-all">
                  <ICONS.RefreshCw size={16} /> Reload
                </button>
              </div>
            </div>
            <button className="flex items-center gap-2 bg-slate-100 text-slate-600 px-4 py-2 rounded-lg text-sm font-bold hover:bg-slate-200 transition-all w-fit">
              <ICONS.Download size={16} /> Export
            </button>
            <div className="bg-white rounded-xl border border-slate-100 overflow-hidden overflow-x-auto">
              <table className="w-full text-left min-w-[1000px]">
                <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
                  <tr>
                    <th className="px-6 py-4">Institution</th>
                    <th className="px-6 py-4">Citizenship</th>
                    <th className="px-6 py-4">Blank</th>
                    <th className="px-6 py-4">Draft</th>
                    <th className="px-6 py-4">Inactive</th>
                    <th className="px-6 py-4">Reopened</th>
                    <th className="px-6 py-4">Submitted</th>
                    <th className="px-6 py-4">Withdrawn</th>
                    <th className="px-6 py-4">Closed</th>
                    <th className="px-6 py-4 font-bold">Total</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {[
                    { inst: 'John von Neumann University', cit: 'AE United Arab Emirates', bl: 4, dr: 0, in: 2, re: 0, sub: 7, with: 0, cl: 0, tot: 13 },
                    { inst: '', cit: 'AF Afghanistan', bl: 3, dr: 0, in: 15, re: 4, sub: 111, with: 2, cl: 0, tot: 135 },
                    { inst: '', cit: 'AO Angola', bl: 0, dr: 0, in: 5, re: 0, sub: 0, with: 0, cl: 0, tot: 5 },
                    { inst: '', cit: 'BD Bangladesh', bl: 143, dr: 0, in: 449, re: 57, sub: 1840, with: 50, cl: 19, tot: 2558 },
                  ].map((row, i) => (
                    <tr key={i} className="hover:bg-slate-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-slate-600">{row.inst}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cit}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.bl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.dr}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.in}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.re}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.sub}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.with}</td>
                      <td className="px-6 py-4 text-sm text-slate-600">{row.cl}</td>
                      <td className="px-6 py-4 text-sm text-slate-600 font-bold">{row.tot}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        );
      default:
        return (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            {reports.map((report) => (
              <button
                key={report.id}
                onClick={() => setSelectedReport(report.id as ReportType)}
                className="bg-white p-6 rounded-2xl border border-slate-100 shadow-sm hover:shadow-md transition-all text-left group"
              >
                <div className="w-12 h-12 bg-amber-50 text-amber-600 rounded-xl flex items-center justify-center mb-4 group-hover:bg-amber-600 group-hover:text-white transition-all">
                  <ICONS.BarChart2 size={24} />
                </div>
                <h4 className="font-bold text-slate-800 mb-2">{report.name}</h4>
                <p className="text-xs text-slate-500 leading-relaxed">{report.description}</p>
              </button>
            ))}
          </div>
        );
    }
  };

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      <div className="flex items-center justify-between border-b border-slate-200 pb-8">
        <div>
          {selectedReport ? (
            <button 
              onClick={() => setSelectedReport(null)}
              className="flex items-center gap-2 text-slate-400 hover:text-amber-600 font-bold text-sm mb-2 transition-all"
            >
              <ICONS.ArrowLeft size={16} /> back
            </button>
          ) : null}
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">
            {selectedReport || 'Riportok'}
          </h2>
          <p className="text-slate-500 mt-1">
            {selectedReport ? reports.find(r => r.id === selectedReport)?.description : 'Válasszon egy riportot az adatok megtekintéséhez.'}
          </p>
        </div>
      </div>

      <div className="animate-in fade-in slide-in-from-bottom-4 duration-500">
        {renderReportContent()}
      </div>
    </div>
  );
};
return Reports;
})();

/* ===== Intelligence ===== */
const Intelligence = (() => {
type SubView = 'duplicates' | 'passports' | 'cross_checks' | 'similarity';

const Intelligence: React.FC = () => {
  const [activeSubView, setActiveSubView] = useState<SubView>('duplicates');
  const [students, setStudents] = useState<Student[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const fetchStudents = async () => {
      try {
        const data = await api.getStudents();
        setStudents(data);
      } catch (error) {
        console.error('Failed to fetch students:', error);
      } finally {
        setIsLoading(false);
      }
    };
    fetchStudents();
  }, []);

  const renderDuplicates = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50 flex justify-between items-center">
          <div>
            <h3 className="font-bold text-slate-800 text-lg">Duplicates Finder</h3>
            <p className="text-xs text-slate-400">Jelentkezők, akik több fiókkal vagy hasonló adatokkal rendelkeznek.</p>
          </div>
          <button className="bg-indigo-600 text-white px-4 py-2 rounded-xl text-sm font-bold flex items-center gap-2 hover:bg-indigo-700 transition-all">
            <ICONS.RefreshCw size={16} /> Újraelemzés
          </button>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Elsődleges Jelentkező</th>
                <th className="px-6 py-4">Gyanús Másolat</th>
                <th className="px-6 py-4">Egyezési Arány</th>
                <th className="px-6 py-4">Közös Adatok</th>
                <th className="px-6 py-4 text-right">Műveletek</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              <tr className="hover:bg-slate-50 transition-colors">
                <td className="px-6 py-4">
                  <p className="font-semibold text-slate-800">John Doe</p>
                  <p className="text-xs text-slate-400">john.doe@example.com</p>
                </td>
                <td className="px-6 py-4">
                  <p className="font-semibold text-slate-800">Johnny Doe</p>
                  <p className="text-xs text-slate-400">j.doe99@gmail.com</p>
                </td>
                <td className="px-6 py-4">
                  <span className="px-2 py-1 bg-red-50 text-red-600 rounded text-[10px] font-bold">92% - MAGAS</span>
                </td>
                <td className="px-6 py-4">
                  <div className="flex gap-1">
                    <span className="px-2 py-0.5 bg-slate-100 text-slate-600 rounded text-[10px] font-bold">Születési dátum</span>
                    <span className="px-2 py-0.5 bg-slate-100 text-slate-600 rounded text-[10px] font-bold">IP cím</span>
                  </div>
                </td>
                <td className="px-6 py-4 text-right">
                  <button className="text-indigo-600 font-bold text-xs hover:underline">Összevonás</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  const renderPassports = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50">
          <h3 className="font-bold text-slate-800 text-lg">Expired Passports</h3>
          <p className="text-xs text-slate-400">Lejárt vagy hamarosan lejáró úti okmányok figyelése.</p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Jelentkező</th>
                <th className="px-6 py-4">Útlevélszám</th>
                <th className="px-6 py-4">Lejárat Dátuma</th>
                <th className="px-6 py-4">Státusz</th>
                <th className="px-6 py-4 text-right">Értesítés</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              {students.slice(0, 3).map(student => (
                <tr key={student.id} className="hover:bg-slate-50 transition-colors">
                  <td className="px-6 py-4">
                    <p className="font-semibold text-slate-800">{student.name}</p>
                    <p className="text-xs text-slate-400">{student.country}</p>
                  </td>
                  <td className="px-6 py-4 font-mono text-xs text-slate-600">AB1234567</td>
                  <td className="px-6 py-4 text-sm text-slate-600">2024.08.15</td>
                  <td className="px-6 py-4">
                    <span className="px-2 py-1 bg-amber-50 text-amber-600 rounded text-[10px] font-bold">6 hónapon belül lejár</span>
                  </td>
                  <td className="px-6 py-4 text-right">
                    <button className="p-2 text-slate-400 hover:text-indigo-600 transition-colors">
                      <ICONS.Mail size={18} />
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  const renderCrossChecks = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50">
          <h3 className="font-bold text-slate-800 text-lg">Data Cross-checks</h3>
          <p className="text-xs text-slate-400">Ellentmondásos adatok keresése a jelentkezési lap és a dokumentumok között.</p>
        </div>
        <div className="p-12 text-center">
          <div className="w-16 h-16 bg-emerald-50 text-emerald-600 rounded-full flex items-center justify-center mx-auto mb-4">
            <ICONS.CheckCircle size={32} />
          </div>
          <h4 className="font-bold text-slate-800">Minden adat konzisztens</h4>
          <p className="text-sm text-slate-400 mt-2">Az utolsó ellenőrzés óta nem találtunk ellentmondást a rendszerben.</p>
        </div>
      </div>
    </div>
  );

  const renderSimilarity = () => (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="bg-white rounded-2xl border border-slate-100 shadow-sm overflow-hidden">
        <div className="p-6 border-b border-slate-50">
          <h3 className="font-bold text-slate-800 text-lg">Similarity Check (Plagiarism)</h3>
          <p className="text-xs text-slate-400">Motivációs levelek és esszék hasonlóságának ellenőrzése más jelentkezőkével.</p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-left">
            <thead className="bg-slate-50 text-slate-400 text-[10px] font-bold uppercase tracking-wider">
              <tr>
                <th className="px-6 py-4">Jelentkező</th>
                <th className="px-6 py-4">Dokumentum</th>
                <th className="px-6 py-4">Hasonlóság</th>
                <th className="px-6 py-4">Forrás</th>
                <th className="px-6 py-4 text-right">Részletek</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-50">
              <tr className="hover:bg-slate-50 transition-colors">
                <td className="px-6 py-4">
                  <p className="font-semibold text-slate-800">Ahmed Khan</p>
                </td>
                <td className="px-6 py-4 text-sm text-slate-600">Motivation Letter.pdf</td>
                <td className="px-6 py-4">
                  <div className="flex items-center gap-2">
                    <div className="w-16 bg-slate-100 h-1.5 rounded-full overflow-hidden">
                      <div className="h-full bg-amber-500 w-[45%]"></div>
                    </div>
                    <span className="text-[10px] font-bold text-amber-600">45%</span>
                  </div>
                </td>
                <td className="px-6 py-4 text-xs text-slate-400 italic">Belső adatbázis (ID: 2841)</td>
                <td className="px-6 py-4 text-right">
                  <button className="text-indigo-600 font-bold text-xs hover:underline">Összehasonlítás</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );

  return (
    <div className="max-w-7xl mx-auto p-8 space-y-8">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 border-b border-slate-200 pb-8">
        <div>
          <h2 className="text-3xl font-extrabold text-slate-900 tracking-tight">Intelligence</h2>
          <p className="text-slate-500 mt-1">Adatminőség, biztonság és csalásmegelőzési eszközök.</p>
        </div>
      </div>

      <div className="flex items-center gap-1 p-1 bg-white border border-slate-100 rounded-2xl w-fit shadow-sm overflow-x-auto max-w-full">
        <button 
          onClick={() => setActiveSubView('duplicates')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'duplicates' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Duplicates Finder
        </button>
        <button 
          onClick={() => setActiveSubView('passports')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'passports' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Expired Passports
        </button>
        <button 
          onClick={() => setActiveSubView('cross_checks')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'cross_checks' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Data Cross-checks
        </button>
        <button 
          onClick={() => setActiveSubView('similarity')}
          className={`px-6 py-3 rounded-xl text-sm font-bold transition-all whitespace-nowrap ${activeSubView === 'similarity' ? 'bg-slate-900 text-white shadow-md' : 'text-slate-500 hover:text-slate-800'}`}
        >
          Similarity Check
        </button>
      </div>

      <div className="mt-8">
        {activeSubView === 'duplicates' && renderDuplicates()}
        {activeSubView === 'passports' && renderPassports()}
        {activeSubView === 'cross_checks' && renderCrossChecks()}
        {activeSubView === 'similarity' && renderSimilarity()}
      </div>
    </div>
  );
};
return Intelligence;
})();


/* ===== AccountPage (profil) ===== */
const accountKey = (email) => 'nje_account_' + (email || 'guest');
const loadAccountOverride = (email) => { try { return JSON.parse(localStorage.getItem(accountKey(email))) || {}; } catch (e) { return {}; } };
const AccountPage = (() => {
const PROFILE_EVENTS = [
  { date: '2026-07-15', label: 'Befizetési határidő', tone: 'red' },
  { date: '2026-08-20', label: 'Dokumentum-pótlási határidő', tone: 'amber' },
  { date: '2026-09-01', label: 'Szemeszter kezdete', tone: 'emerald' },
  { date: '2026-09-02', label: 'Felvételi interjúk kezdete', tone: 'primary' },
  { date: '2026-09-15', label: 'Beiratkozási határidő', tone: 'primary' },
];
const CAL_TONE_DOT = { red: 'bg-red-500', amber: 'bg-amber-500', emerald: 'bg-emerald-500', primary: 'bg-primary' };
const CAL_TONE_SOFT = { red: 'bg-red-50 text-red-600', amber: 'bg-amber-50 text-amber-600', emerald: 'bg-emerald-50 text-emerald-600', primary: 'bg-primary/10 text-primary' };
const HU_MONTHS = ['Január','Február','Március','Április','Május','Június','Július','Augusztus','Szeptember','Október','November','December'];
function MiniCalendar({ events }) {
  const start = events && events[0] ? new Date(events[0].date) : new Date();
  const [cur, setCur] = useState(new Date(start.getFullYear(), start.getMonth(), 1));
  const y = cur.getFullYear(), m = cur.getMonth();
  const dayNames = ['H','K','Sze','Cs','P','Szo','V'];
  const firstDow = (new Date(y, m, 1).getDay() + 6) % 7;
  const daysInMonth = new Date(y, m + 1, 0).getDate();
  const evByDay = {};
  (events || []).forEach(e => { const d = new Date(e.date); if (d.getFullYear() === y && d.getMonth() === m) { (evByDay[d.getDate()] = evByDay[d.getDate()] || []).push(e); } });
  const cells = [];
  for (let i = 0; i < firstDow; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);
  const today = new Date();
  const isToday = (d) => today.getFullYear() === y && today.getMonth() === m && today.getDate() === d;
  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div className="font-bold text-slate-800">{HU_MONTHS[m]} {y}</div>
        <div className="flex items-center gap-1">
          <button onClick={() => setCur(new Date(y, m - 1, 1))} className="w-7 h-7 rounded-lg hover:bg-slate-100 flex items-center justify-center text-slate-500"><Lucide.ChevronLeft size={16} /></button>
          <button onClick={() => setCur(new Date(y, m + 1, 1))} className="w-7 h-7 rounded-lg hover:bg-slate-100 flex items-center justify-center text-slate-500"><Lucide.ChevronRight size={16} /></button>
        </div>
      </div>
      <div className="grid grid-cols-7 gap-1 text-center mb-1">{dayNames.map(d => <div key={d} className="text-[10px] font-bold text-slate-400 uppercase py-1">{d}</div>)}</div>
      <div className="grid grid-cols-7 gap-1">
        {cells.map((d, i) => {
          if (!d) return <div key={i}></div>;
          const evs = evByDay[d];
          return (
            <div key={i} className={'aspect-square rounded-lg flex flex-col items-center justify-center text-sm relative ' + (isToday(d) ? 'bg-slate-900 text-white font-bold' : evs ? 'bg-slate-50 text-slate-700 font-bold' : 'text-slate-400')} title={evs ? evs.map(e => e.label).join(', ') : ''}>
              {d}
              {evs && <div className="absolute bottom-1 flex gap-0.5">{evs.slice(0, 3).map((e, j) => <span key={j} className={'w-1 h-1 rounded-full ' + (isToday(d) ? 'bg-white' : CAL_TONE_DOT[e.tone])}></span>)}</div>}
            </div>
          );
        })}
      </div>
    </div>
  );
}
const AccountPage = ({ user, onUpdate, onClose }) => {
  const [name, setName] = useState(user.name || '');
  const [phone, setPhone] = useState(user.phone || '');
  const [country, setCountry] = useState(user.country || '');
  const [birthDate, setBirthDate] = useState(user.birthDate || '');
  const [avatar, setAvatar] = useState(user.avatar || '');
  const [savedInfo, setSavedInfo] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [pw, setPw] = useState({ next: '', confirm: '' });
  const [pwState, setPwState] = useState({ busy: false, msg: '', ok: false });
  const fileRef = React.useRef(null);

  const persist = (patch) => {
    const cur = loadAccountOverride(user.email);
    const next = { ...cur, ...patch };
    try { localStorage.setItem(accountKey(user.email), JSON.stringify(next)); } catch (e) {}
  };

  const onPickFile = async (e) => {
    const f = e.target.files && e.target.files[0];
    if (!f) return;
    setUploading(true);
    try {
      if (window.sb && user.id) {
        const ext = (f.name.split('.').pop() || 'png').toLowerCase();
        const path = user.id + '/avatar_' + Date.now() + '.' + ext;
        const { error: upErr } = await sb.storage.from('avatars').upload(path, f, { upsert: true, contentType: f.type });
        if (!upErr) {
          const { data: pub } = sb.storage.from('avatars').getPublicUrl(path);
          const url = pub.publicUrl;
          try { await sb.from('profiles').update({ avatar_url: url }).eq('id', user.id); } catch (e) {}
          setAvatar(url); persist({ avatar: url }); onUpdate({ avatar: url }); setUploading(false); return;
        }
      }
    } catch (err) { /* fall back to local */ }
    const reader = new FileReader();
    reader.onload = () => { const url = reader.result; setAvatar(url); persist({ avatar: url }); onUpdate({ avatar: url }); setUploading(false); };
    reader.readAsDataURL(f);
  };
  const removeAvatar = async () => { const fallback = 'https://i.pravatar.cc/150?u=' + encodeURIComponent(user.email || 'u'); setAvatar(fallback); persist({ avatar: '' }); onUpdate({ avatar: fallback }); try { if (window.sb && user.id) await sb.from('profiles').update({ avatar_url: null }).eq('id', user.id); } catch (e) {} };

  const saveInfo = async () => {
    persist({ name, phone, country, birthDate });
    onUpdate({ name, phone, country, birthDate });
    try { if (window.sb && user.id) await sb.from('profiles').update({ name }).eq('id', user.id); } catch (e) {}
    setSavedInfo(true); setTimeout(() => setSavedInfo(false), 2500);
  };

  const changePassword = async () => {
    if (pw.next.length < 6) { setPwState({ busy: false, ok: false, msg: 'A jelszó legalább 6 karakter legyen.' }); return; }
    if (pw.next !== pw.confirm) { setPwState({ busy: false, ok: false, msg: 'A két jelszó nem egyezik.' }); return; }
    setPwState({ busy: true, ok: false, msg: '' });
    try {
      const { error } = await sb.auth.updateUser({ password: pw.next });
      if (error) { setPwState({ busy: false, ok: false, msg: error.message || 'A jelszó módosítása sikertelen.' }); return; }
      setPw({ next: '', confirm: '' });
      setPwState({ busy: false, ok: true, msg: 'A jelszó megváltozott.' });
    } catch (e) { setPwState({ busy: false, ok: false, msg: 'Kapcsolati hiba.' }); }
  };

  const inCls = 'w-full px-3.5 py-2.5 rounded-xl border border-slate-200 text-sm text-slate-900 placeholder-slate-400 focus:border-primary focus:ring-2 focus:ring-primary/20 outline-none transition-all';
  const lblCls = 'block text-xs font-bold text-slate-500 uppercase tracking-wide mb-1.5';
  const roleLabel = { ADMIN: 'Rendszergazda', ADMISSIONS: 'Felvételi munkatárs', FINANCE: 'Pénzügy', AGENT: 'Ügynök', STUDENT: 'Jelentkező' }[user.role] || user.role;
  const events = PROFILE_EVENTS;
  const upcoming = [...events].filter(e => new Date(e.date) >= new Date('2026-06-30')).sort((a, b) => new Date(a.date) - new Date(b.date));
  const messages = React.useMemo(() => { try { const v = JSON.parse(localStorage.getItem('nje_messages_' + (user.email || 'guest'))); return Array.isArray(v) ? v : []; } catch (e) { return []; } }, [user.email]);
  const recentMsgs = [...messages].sort((a, b) => (a.read === b.read) ? 0 : (a.read ? 1 : -1)).slice(0, 5);
  const fmtDate = (iso) => { const d = new Date(iso); return d.getFullYear() + '. ' + HU_MONTHS[d.getMonth()].toLowerCase() + ' ' + d.getDate() + '.'; };

  return (
    <div className="p-8 max-w-4xl mx-auto animate-in fade-in slide-in-from-bottom-4 duration-500">
      <button onClick={onClose} className="text-sm text-slate-400 hover:text-slate-600 mb-5 inline-flex items-center gap-1.5"><Lucide.ChevronLeft size={15} /> Vissza</button>
      <div className="mb-8">
        <p className="text-slate-400 text-xs font-bold uppercase tracking-widest mb-1">Fiók</p>
        <h2 className="text-3xl font-black text-slate-800">Profilom</h2>
      </div>

      {/* fej */}
      <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-7 flex flex-col sm:flex-row items-center gap-6 mb-6">
        <div className="relative group">
          <div className="w-24 h-24 rounded-3xl overflow-hidden bg-primary/10 shadow-sm">
            <img src={avatar} alt="" className="w-full h-full object-cover" />
            {uploading && <div className="absolute inset-0 bg-slate-900/40 rounded-3xl flex items-center justify-center"><Lucide.Loader2 size={22} className="text-white animate-spin" /></div>}
          </div>
          <button onClick={() => fileRef.current && fileRef.current.click()} className="absolute -bottom-2 -right-2 w-9 h-9 rounded-xl bg-primary text-white flex items-center justify-center shadow-lg hover:bg-primary/90 transition-all"><Lucide.Camera size={16} /></button>
          <input ref={fileRef} type="file" accept="image/*" onChange={onPickFile} className="hidden" />
        </div>
        <div className="text-center sm:text-left flex-1">
          <h3 className="text-xl font-black text-slate-800">{name || user.name}</h3>
          <p className="text-sm text-slate-400">{user.email}</p>
          <div className="mt-2 inline-flex px-3 py-1 bg-primary/10 text-primary rounded-full text-[11px] font-bold uppercase tracking-wide">{roleLabel}</div>
        </div>
        <div className="flex flex-col gap-2">
          <button onClick={() => fileRef.current && fileRef.current.click()} className="px-4 py-2 rounded-xl bg-slate-900 text-white text-xs font-bold hover:bg-slate-800 inline-flex items-center gap-1.5"><Lucide.Upload size={14} /> Kép feltöltése</button>
          <button onClick={removeAvatar} className="px-4 py-2 rounded-xl bg-slate-100 text-slate-500 text-xs font-bold hover:bg-slate-200 inline-flex items-center gap-1.5"><Lucide.Trash2 size={14} /> Eltávolítás</button>
        </div>
      </div>

      <div className="grid lg:grid-cols-2 gap-6">
        {/* alapadatok */}
        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-7">
          <h4 className="font-bold text-slate-800 mb-5 flex items-center gap-2"><Lucide.User size={18} className="text-primary" /> Alapadatok</h4>
          <div className="space-y-4">
            <div><label className={lblCls}>Teljes név</label><input className={inCls} value={name} onChange={e => setName(e.target.value)} /></div>
            <div><label className={lblCls}>E-mail</label><input className={inCls + ' bg-slate-50 text-slate-400 cursor-not-allowed'} value={user.email} disabled /><p className="text-[11px] text-slate-400 mt-1">Az e-mail cím nem módosítható.</p></div>
            <div><label className={lblCls}>Telefonszám</label><input className={inCls} value={phone} onChange={e => setPhone(e.target.value)} placeholder="+36…" /></div>
            <div><label className={lblCls}>Állampolgárság</label><input className={inCls} list="acc-countries" value={country} onChange={e => setCountry(e.target.value)} placeholder="Pl. Nigeria" /><datalist id="acc-countries">{((JourneyShared && JourneyShared.COUNTRIES) || []).map(c => <option key={c} value={c} />)}</datalist></div>
            <div><label className={lblCls}>Születési dátum</label><input type="date" className={inCls} value={birthDate} onChange={e => setBirthDate(e.target.value)} /></div>
          </div>
          <div className="mt-6 flex items-center gap-3">
            <button onClick={saveInfo} className="bg-primary text-white px-5 py-2.5 rounded-xl font-bold text-sm hover:bg-primary/90 inline-flex items-center gap-2"><Lucide.Check size={16} /> Mentés</button>
            {savedInfo && <span className="text-xs font-bold text-emerald-600 inline-flex items-center gap-1"><Lucide.CheckCircle2 size={14} /> Elmentve</span>}
          </div>
        </div>

        {/* jelszó */}
        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-7">
          <h4 className="font-bold text-slate-800 mb-5 flex items-center gap-2"><Lucide.Lock size={18} className="text-primary" /> Jelszó módosítása</h4>
          <div className="space-y-4">
            <div><label className={lblCls}>Új jelszó</label><input type="password" className={inCls} value={pw.next} onChange={e => setPw({ ...pw, next: e.target.value })} placeholder="Legalább 6 karakter" /></div>
            <div><label className={lblCls}>Új jelszó megerősítése</label><input type="password" className={inCls} value={pw.confirm} onChange={e => setPw({ ...pw, confirm: e.target.value })} /></div>
          </div>
          {pwState.msg && <div className={'mt-4 text-xs font-bold inline-flex items-center gap-1.5 ' + (pwState.ok ? 'text-emerald-600' : 'text-red-500')}>{pwState.ok ? <Lucide.CheckCircle2 size={14} /> : <Lucide.AlertCircle size={14} />} {pwState.msg}</div>}
          <div className="mt-6">
            <button onClick={changePassword} disabled={pwState.busy || !pw.next} className="bg-slate-900 text-white px-5 py-2.5 rounded-xl font-bold text-sm hover:bg-slate-800 disabled:opacity-40 disabled:cursor-not-allowed inline-flex items-center gap-2"><Lucide.KeyRound size={16} /> {pwState.busy ? 'Mentés…' : 'Jelszó módosítása'}</button>
          </div>
        </div>
      </div>

      {/* naptár + üzenetek */}
      <div className="grid lg:grid-cols-2 gap-6 mt-6">
        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-7">
          <h4 className="font-bold text-slate-800 mb-5 flex items-center gap-2"><Lucide.CalendarDays size={18} className="text-primary" /> Határidők és dátumok</h4>
          <MiniCalendar events={events} />
          <div className="mt-5 pt-5 border-t border-slate-100 space-y-2.5">
            <div className="text-[11px] font-bold text-slate-400 uppercase tracking-wide">Közelgő események</div>
            {upcoming.map((e, i) => (
              <div key={i} className="flex items-center gap-3">
                <div className={'w-10 h-10 rounded-xl flex flex-col items-center justify-center font-bold flex-none ' + CAL_TONE_SOFT[e.tone]}><span className="text-[9px] uppercase leading-none">{HU_MONTHS[new Date(e.date).getMonth()].slice(0, 3)}</span><span className="text-sm leading-none">{new Date(e.date).getDate()}</span></div>
                <div className="min-w-0"><div className="text-sm font-bold text-slate-700 truncate">{e.label}</div><div className="text-xs text-slate-400">{fmtDate(e.date)}</div></div>
              </div>
            ))}
          </div>
        </div>

        <div className="bg-white rounded-3xl border border-slate-100 shadow-sm p-7">
          <div className="flex items-center justify-between mb-5"><h4 className="font-bold text-slate-800 flex items-center gap-2"><Lucide.Mail size={18} className="text-primary" /> Legutóbbi üzenetek</h4>{recentMsgs.length > 0 && <span className="text-[10px] font-bold px-2 py-1 rounded-full bg-primary/10 text-primary">{messages.filter(m => !m.read).length} új</span>}</div>
          {recentMsgs.length === 0 ? (
            <div className="text-center py-10 text-slate-400"><Lucide.Inbox size={32} className="mx-auto mb-2 text-slate-300" /><div className="text-sm">Nincs üzenet</div></div>
          ) : (
            <div className="space-y-1">
              {recentMsgs.map(m => (
                <div key={m.id} className={'p-3 rounded-xl flex items-start gap-3 ' + (!m.read ? 'bg-primary/5' : 'hover:bg-slate-50')}>
                  <div className={'w-9 h-9 rounded-lg flex items-center justify-center shrink-0 ' + (m.tone === 'success' ? 'bg-emerald-50 text-emerald-600' : m.tone === 'warning' ? 'bg-amber-50 text-amber-600' : m.tone === 'action' ? 'bg-primary/10 text-primary' : 'bg-slate-100 text-slate-400')}><Lucide.Mail size={15} /></div>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2"><span className={'text-xs truncate ' + (!m.read ? 'font-bold text-slate-900' : 'text-slate-500')}>{/Rendszer|System/.test(m.sender||'') ? m.sender : 'Külügyi Iroda'}</span><span className="text-[10px] text-slate-400 shrink-0">{m.date}</span></div>
                    <div className={'text-xs truncate ' + (!m.read ? 'font-bold text-slate-800' : 'text-slate-500')}>{m.subject}</div>
                    <div className="text-[11px] text-slate-400 truncate">{m.preview}</div>
                  </div>
                  {!m.read && <span className="w-2 h-2 bg-primary rounded-full mt-1.5 shrink-0"></span>}
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
};
return AccountPage;
})();

/*__FEATURES__*/

/* ===== App ===== */
const App = (() => {
const App: React.FC = () => {
  const [currentUser, setCurrentUser] = useState<User | null>(null);
  const [activeView, setActiveView] = useState<AppView>(AppView.AGENT_PORTAL);
  const [loginEmail, setLoginEmail] = useState('');
  const [loginPassword, setLoginPassword] = useState('');
  const [loginError, setLoginError] = useState('');
  const [authBusy, setAuthBusy] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [showAccount, setShowAccount] = useState(false);
  const updateCurrentUser = (patch) => setCurrentUser(u => u ? { ...u, ...patch } : u);

  // Default landing view per role.
  const viewForRole = (role) => {
    return AppView.FEED; // Campus Feed is the shared landing for every role
  };

  // Build the app user from the Supabase session + profiles row.
  const loadProfile = async (authUser) => {
    let profile = null;
    try {
      const { data } = await sb.from('profiles').select('*').eq('id', authUser.id).maybeSingle();
      profile = data;
    } catch (e) { /* profile may not exist yet */ }
    const meta = authUser.user_metadata || {};
    const role = (profile && profile.role) || meta.role || 'STUDENT';
    // Registrations need superadmin approval (migration 07). Gate on
    // `approval_status` only when the column actually exists, so this build
    // also runs against a database where 07 has not been applied yet — there,
    // every account stays usable exactly as before. RLS ensures the profile
    // row is always readable by its owner, so a null profile is not a pending
    // one. NB: `profiles.status` belongs to a different app sharing this
    // Supabase project — never read or write it here.
    const hasApprovalFlow = !!profile && Object.prototype.hasOwnProperty.call(profile, 'approval_status');
    const status = hasApprovalFlow ? (profile.approval_status || 'pending') : 'approved';
    const ov = loadAccountOverride(authUser.email);
    setCurrentUser({
      id: (profile && profile.id) || authUser.id,
      name: ov.name || (profile && profile.name) || meta.name || authUser.email,
      email: authUser.email,
      role,
      status,
      rejected_reason: profile && profile.rejected_reason,
      phone: ov.phone || (profile && profile.phone) || '',
      country: ov.country || (profile && profile.country) || '',
      birthDate: ov.birthDate || (profile && profile.birthDate) || '',
      agencyId: profile && profile.agencyId,
      avatar: (profile && profile.avatar_url) || ov.avatar || 'https://i.pravatar.cc/150?u=' + encodeURIComponent(authUser.email),
    });
    // Land the superadmin on the approvals queue when something is waiting;
    // everyone else (and an empty queue) gets the Campus Feed.
    let view = viewForRole(role);
    if (status === 'approved' && role === 'SUPERADMIN' && (await REG_pendingCount()) > 0) {
      view = AppView.REGISTRATIONS;
    }
    setActiveView(view);
  };

  // Check the existing session on load, and react to sign-in / sign-out.
  useEffect(() => {
    let sub = null;
    (async () => {
      try {
        const { data: { session } } = await sb.auth.getSession();
        if (session && session.user) await loadProfile(session.user);
      } catch (e) {
        console.error('Session check failed', e);
      } finally {
        setIsLoading(false);
      }
      const { data } = sb.auth.onAuthStateChange((_event, session) => {
        if (session && session.user) loadProfile(session.user);
        else setCurrentUser(null);
      });
      sub = data && data.subscription;
    })();
    return () => { if (sub) sub.unsubscribe(); };
  }, []);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoginError('');
    setAuthBusy(true);
    try {
      const { error } = await sb.auth.signInWithPassword({ email: loginEmail.trim(), password: loginPassword });
      if (error) { setLoginError(error.message || 'A bejelentkezés sikertelen.'); setAuthBusy(false); return; }
      // onAuthStateChange loads the profile and sets the current user.
    } catch (err) {
      setLoginError('Kapcsolódási hiba. Kérjük, próbálja újra.');
      setAuthBusy(false);
    }
  };

  const handleLogout = async () => {
    try { await sb.auth.signOut(); } catch (e) { /* ignore */ }
    setCurrentUser(null);
    window.location.href = 'index.html';
  };

  if (isLoading) {
    return (
      <div className="min-h-screen bg-slate-900 flex items-center justify-center p-6 font-sans">
        <div className="text-white flex flex-col items-center gap-4">
          <div className="w-12 h-12 border-4 border-primary border-t-transparent rounded-full animate-spin"></div>
          <p className="text-slate-400 font-medium">Rendszer betöltése...</p>
        </div>
      </div>
    );
  }

  if (!currentUser) {
    return (
      <div className="min-h-screen bg-slate-900 flex items-center justify-center p-6 font-sans">
        <div className="max-w-md w-full bg-white rounded-3xl shadow-2xl overflow-hidden p-10 animate-in zoom-in-95 duration-500">
          <div className="flex flex-col items-center mb-10">
            <img 
              src={NJE_LOGO} 
              alt="NJE Logo" 
              className="h-24 object-contain mb-6"
              referrerPolicy="no-referrer"
            />
            <h1 className="text-2xl font-black text-slate-900 tracking-tight">UniPortal Pro</h1>
            <p className="text-slate-400 text-sm mt-2">Kérjük, jelentkezzen be a folytatáshoz</p>
          </div>
          <form onSubmit={handleLogin} className="space-y-5">
            <div>
              <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">E-mail cím</label>
              <input 
                type="email" 
                value={loginEmail}
                onChange={(e) => setLoginEmail(e.target.value)}
                placeholder="pl. admin@uni.hu"
                className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                required
              />
            </div>
            <div>
              <label className="text-[10px] font-black text-slate-400 uppercase tracking-widest block mb-2">Jelszó</label>
              <input 
                type="password" 
                value={loginPassword}
                onChange={(e) => setLoginPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full bg-slate-50 border border-slate-100 rounded-2xl px-5 py-4 text-sm focus:outline-none focus:ring-2 focus:ring-primary/20 transition-all"
                required
              />
            </div>
            {loginError && (
              <div className="text-[12px] font-semibold text-red-600 bg-red-50 border border-red-100 rounded-xl px-3 py-2.5">{loginError}</div>
            )}
            <button disabled={authBusy} className="w-full bg-primary text-white py-4 rounded-2xl font-bold shadow-xl shadow-primary/10 hover:bg-primary/90 transition-all active:scale-95 disabled:opacity-60">
              {authBusy ? 'Bejelentkezés…' : 'Belépés a rendszerbe'}
            </button>
          </form>
          <div className="mt-8 pt-8 border-t border-slate-50">
            <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-3">Teszt fiókok · jelszó: <code className="text-primary normal-case tracking-normal">Demo1234!</code></p>
            <div className="grid grid-cols-2 gap-2">
              {[['ADMIN','admin@uni.hu'],['FELVÉTELI','admissions@uni.hu'],['PÉNZÜGY','finance@uni.hu'],['ÜGYNÖK','agent@globalstudy.com'],['HALLGATÓ','ammar@test.com']].map(([role, email]) => (
                <button
                  key={email}
                  type="button"
                  onClick={() => { setLoginEmail(email); setLoginPassword('Demo1234!'); }}
                  className="text-left px-3 py-2 rounded-xl bg-slate-50 hover:bg-primary/10 transition-colors"
                >
                  <span className="block text-[9px] font-black text-slate-400 uppercase tracking-wider">{role}</span>
                  <span className="block text-[11px] font-bold text-slate-600 truncate">{email}</span>
                </button>
              ))}
            </div>
          </div>
          <a href="index.html" className="block text-center mt-6 text-xs font-bold text-slate-400 hover:text-primary transition-colors">← Vissza a főoldalra</a>
        </div>
      </div>
    );
  }

  // Signed in, but the superadmin has not approved (or has revoked) access.
  // The RLS policies from migration 07 enforce the same thing server-side —
  // this screen only explains it.
  if (currentUser.status !== 'approved') {
    return <PendingApprovalScreen user={currentUser} onLogout={handleLogout} />;
  }

  // Filter menu items based on user role
  const filteredMenuItems = MENU_ITEMS.filter(item => {
    // Approving registrations is the superadmin's alone — not even ADMIN.
    if (item.id === AppView.REGISTRATIONS) return currentUser.role === 'SUPERADMIN';
    if (currentUser.role === 'SUPERADMIN' || currentUser.role === 'ADMIN') return true;
    if (currentUser.role === 'AGENT') return [AppView.FEED, AppView.PROGRAMS, AppView.ASSISTANT, AppView.AGENT_PORTAL, AppView.INTERVIEWS].includes(item.id);
    if (currentUser.role === 'FINANCE') return [AppView.FEED, AppView.ASSISTANT, AppView.FINANCE, AppView.AGENT_PORTAL, AppView.INTERVIEWS, AppView.REPORTS].includes(item.id);
    if (currentUser.role === 'ADMISSIONS') return [AppView.FEED, AppView.ASSISTANT, AppView.ADMISSIONS_CORE, AppView.EVALUATION, AppView.ENGAGEMENT_CRM, AppView.IMMIGRATION, AppView.INTERVIEWS, AppView.MARKETING_LEADS, AppView.REPORTS, AppView.INTELLIGENCE].includes(item.id);
    if (currentUser.role === 'STUDENT') return [AppView.FEED, AppView.PROGRAMS, AppView.ASSISTANT, AppView.STUDENT_PORTAL].includes(item.id);
    return false;
  });

  const renderContent = () => {
    switch (activeView) {
      case AppView.AGENT_PORTAL: return <AgentPortal user={currentUser} />;
      case AppView.ADMISSIONS_CORE: return <AdmissionsCore user={currentUser} />;
      case AppView.ENGAGEMENT_CRM: return <EngagementCRM />;
      case AppView.FINANCE: return <Finance />;
      case AppView.IMMIGRATION: return <ImmigrationCompliance />;
      case AppView.EVALUATION: return <Evaluation />;
      case AppView.SYSTEM_ADMIN: return <SystemAdmin />;
      case AppView.INTERVIEWS: return <InterviewScheduler user={currentUser} />;
      case AppView.STUDENT_PORTAL: return <StudentPortal user={currentUser} />;
      case AppView.MARKETING_LEADS: return <MarketingLeads />;
      case AppView.REPORTS: return <Reports />;
      case AppView.INTELLIGENCE: return <Intelligence />;
      case AppView.FEED: return <FeedView user={currentUser} onNavigate={setActiveView} />;
      case AppView.PROGRAMS: return <ProgramsView user={currentUser} scope="programs" />;
      case AppView.TRAININGS: return <ProgramsView user={currentUser} scope="degrees" />;
      case AppView.ASSISTANT: return <AssistantView user={currentUser} />;
      case AppView.REGISTRATIONS:
        return currentUser.role === 'SUPERADMIN'
          ? <RegistrationsView user={currentUser} />
          : <FeedView user={currentUser} onNavigate={setActiveView} />;
      default: return <FeedView user={currentUser} onNavigate={setActiveView} />;
    }
  };

  return (
    <div className="min-h-screen bg-slate-50 flex">
      <Sidebar 
        activeView={activeView} 
        setActiveView={(v) => { setShowAccount(false); setActiveView(v); }} 
        currentUser={currentUser}
        onLogout={handleLogout}
        onOpenProfile={() => setShowAccount(true)}
        menuItems={filteredMenuItems}
      />
      
      <main className="flex-1 ml-72">
        <header className="h-20 bg-white border-b border-slate-200 px-8 flex items-center justify-between sticky top-0 z-50">
          <div className="relative flex-1 max-w-xl">
            <span className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400">
              <ICONS.Search size={18} />
            </span>
            <input 
              type="text" 
              placeholder="Globális keresés a tesztadatok között..." 
              className="w-full pl-12 pr-4 py-2.5 bg-slate-50 border border-slate-100 rounded-xl focus:outline-none focus:ring-2 focus:ring-primary/20 focus:border-primary transition-all text-sm"
            />
          </div>
          
          <div className="flex items-center gap-4">
            <div className="px-3 py-1 bg-primary/10 text-primary rounded-full text-[10px] font-black uppercase tracking-widest">
              {currentUser.role} Mód
            </div>
            <button onClick={() => { const cur = (localStorage.getItem('nje_lang') || 'hu'); localStorage.setItem('nje_lang', cur === 'hu' ? 'en' : 'hu'); window.location.reload(); }} className="h-10 px-2.5 flex items-center gap-1.5 rounded-xl hover:bg-slate-50 transition-colors text-slate-500" title="Language / Nyelv">
              <ICONS.Globe size={19} />
              <span className="text-[11px] font-black tracking-wide">{(typeof localStorage !== 'undefined' && localStorage.getItem('nje_lang') === 'en') ? 'EN' : 'HU'}</span>
            </button>
            <button className="w-10 h-10 flex items-center justify-center rounded-xl hover:bg-slate-50 transition-colors text-slate-500 relative">
              <ICONS.Bell size={20} />
              <span className="absolute top-2.5 right-2.5 w-2 h-2 bg-red-500 rounded-full border-2 border-white"></span>
            </button>
            <button onClick={() => setShowAccount(true)} className="flex items-center gap-2.5 pl-1 pr-3 py-1 rounded-xl hover:bg-slate-50 transition-colors" title="Profilom">
              <span className="w-9 h-9 rounded-lg overflow-hidden bg-primary/10 shadow-sm"><img src={currentUser.avatar} alt="" className="w-full h-full object-cover" /></span>
              <span className="text-left hidden sm:block"><span className="block text-xs font-black text-slate-700 leading-tight">{currentUser.name}</span><span className="block text-[10px] text-slate-400 leading-tight">Profil megnyitása</span></span>
            </button>
          </div>
        </header>

        <div className="relative">
          {showAccount ? <AccountPage user={currentUser} onUpdate={updateCurrentUser} onClose={() => setShowAccount(false)} /> : renderContent()}
        </div>
      </main>
      {['STUDENT', 'AGENT'].includes(currentUser.role) && activeView !== AppView.ASSISTANT && !showAccount && <AssistantWidget user={currentUser} />}
    </div>
  );
};
return App;
})();

/* ===== mount ===== */
const rootElement = document.getElementById('root');
ReactDOM.createRoot(rootElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
const __boot = document.getElementById('__boot');
if (__boot) __boot.remove();

/* ============================================================
   i18n — futásidejű HU→EN fordítás (DOM-alapú)
   A nyelvváltó a fejlécben: localStorage 'nje_lang' + reload.
   ============================================================ */
const HU_EN = {
  // menü / nav
  'Ügynök és partner portál':'Agent & Partner Portal','Jelentkezés és Felvételi':'Applications & Admissions','Kommunikáció és CRM':'Communication & CRM','Pénzügyek':'Finance','Vízum és Compliance':'Visa & Compliance','Felvételi Bírálat':'Admissions Review','Interjú Foglalás':'Interview Booking','Marketing és Lead kezelés':'Marketing & Lead Management','Hallgatói Portál':'Student Portal','Riportok':'Reports','Rendszerkezelés':'System Administration','Regisztrációk':'Registrations','Intelligence':'Intelligence','Hírfolyam':'Feed','Programok':'Programs','Képzések':'Degrees','AI Asszisztens':'AI Assistant','Neumann János Egyetem':'John von Neumann University',
  // fejléc
  'Globális keresés a tesztadatok között...':'Global search across demo data...','Profil megnyitása':'Open profile','Profilom':'My profile','Vissza':'Back','Mentés':'Save','Mentés…':'Saving…','Elmentve':'Saved','Bezárás':'Close','Összes':'View all',
  // profil
  'Fiók':'Account','Alapadatok':'Basic information','Teljes név':'Full name','E-mail':'Email','Telefonszám':'Phone number','Az e-mail cím nem módosítható.':'The email address cannot be changed.','Jelszó módosítása':'Change password','Új jelszó':'New password','Új jelszó megerősítése':'Confirm new password','Legalább 6 karakter':'At least 6 characters','A jelszó legalább 6 karakter legyen.':'Password must be at least 6 characters.','A két jelszó nem egyezik.':'The two passwords do not match.','A jelszó megváltozott.':'Password changed.','A jelszó módosítása sikertelen.':'Failed to change password.','Kapcsolati hiba.':'Connection error.','Kép feltöltése':'Upload image','Eltávolítás':'Remove','Határidők és dátumok':'Deadlines & dates','Közelgő események':'Upcoming events','Legutóbbi üzenetek':'Recent messages','Nincs üzenet':'No messages','Befizetési határidő':'Payment deadline','Folyamat megnyitása':'Open process','Lezárt folyamat megtekintése':'Viewing a closed process','Megnézheted a feltöltött dokumentumokat és a felvételi levelet.':'You can review the uploaded documents and the acceptance letter.','Bezárás':'Close','Megtekintés':'View','Szimulált előnézet':'Simulated preview','Jelentkező adatai':'Applicant details','A profilból':'From profile','Ezek az adatok a profilodból származnak. Módosítani a Profilom oldalon tudod.':'This data comes from your profile. You can edit it on the My Profile page.','Pl. Nigeria':'e.g. Nigeria','Dokumentum-pótlási határidő':'Document submission deadline','Szemeszter kezdete':'Semester start','Felvételi interjúk kezdete':'Admission interviews begin','Beiratkozási határidő':'Enrollment deadline','Rendszergazda':'Administrator','Felvételi munkatárs':'Admissions officer','Pénzügy':'Finance','Ügynök':'Agent','Jelentkező':'Applicant','Fontos dátumok':'Important dates',
  // student dashboard / tabs
  'Áttekintés':'Overview','Dokumentumok':'Documents','Interjúk':'Interviews','Üzenetek':'Messages','Jelentkezés':'Application','Felvételi folyamat':'Admission process','Folyamatban':'In progress','Interjú foglalva':'Interview booked','Felvéve':'Admitted','Olvasatlan üzenet':'Unread messages','Felvételi folyamataim':'My admission processes','Még nincs felvételi folyamat.':'No admission process yet.','Indíts egyet':'Start one','Nincs szak':'No program','Nincs aktív jelentkezés':'No active application','Úgy tűnik, még nem indítottál jelentkezést a rendszerben.':'It looks like you have not started an application yet.','Jelentkezés indítása':'Start application',
  // journey lépések + címek
  'Adatok':'Details','Szakok':'Programs','Ellenőrzés':'Verification','Matek':'Math','Interjú':'Interview','Felvételi levél':'Acceptance letter','Jelentkezői adatok':'Applicant details','Dokumentum-ellenőrzés':'Document verification','Matematika szintfelmérő':'Math placement test','Dokumentumok feltöltése':'Document upload','Szakválasztás':'Program selection','Online interjú foglalása':'Book an online interview','Felvételi folyamatok':'Admission processes','Új folyamat':'New process','Új felvételi folyamat':'New admission process','Nincs szak kiválasztva':'No program selected','Folytatás':'Continue','Megnyitás':'Open','Folyamatok áttekintése':'Process overview','Újraindítás':'Restart','Új jelentkezés':'New application','Jelentkezés lezárva':'Application completed','A feltételes felvételi levelet kiállítottuk és iktattuk. Az interjú a Teams-ben létrejött.':'The conditional acceptance letter has been issued and filed. The interview has been created in Teams.',
  // register step
  'Adatok megadása':'Enter your details','A megadott adatokat később az útlevél-ellenőrzés is felülírhatja.':'The data you enter may later be overwritten by passport verification.','Állampolgárság':'Citizenship','Kezdjen el gépelni…':'Start typing…','Nincs találat':'No results','Születési dátum':'Date of birth','Az adatokat a GDPR szerint kezeljük.':'We handle your data in accordance with GDPR.','Fiók létrehozása':'Create account',
  // programs step
  'Válassza ki a szakokat — egyszerre több szakra is jelentkezhet. A bírálat szakonként történik.':'Select your programs — you can apply to several at once. Each is reviewed separately.','Alapképzés (BSc)':'Undergraduate (BSc)','Mesterképzés / Doktori (MA · MBA · PhD)':'Graduate / Doctoral (MA · MBA · PhD)','Előkészítő kurzus':'Preparatory course',
  // documents step
  'Iskolai tanulmányi adatok':'Academic records','Bizonyítvány / diploma / leckekönyv':'Certificate / diploma / transcript','Útlevél':'Passport','Érvényes úti okmány adatoldala':'Data page of a valid travel document','Nyelvvizsga':'Language exam','Angol nyelvtudás igazolása (B2+)':'Proof of English proficiency (B2+)','Motivációs levél':'Motivation letter','Min. 1 oldal, angol nyelven':'Min. 1 page, in English','Szakmai gyakorlat':'Work experience','Igazolás (ha releváns)':'Certificate (if relevant)','Feltöltés':'Upload','Csere':'Replace','Kinyert adatok':'Extracted data','Az útlevélből automatikusan kinyert mezők — ellenőrizhető és javítható.':'Fields automatically extracted from the passport — reviewable and editable.','Név (útlevél szerint)':'Name (as in passport)','Útlevélszám':'Passport number','Ország':'Country','Szül. dátum':'DOB','AI adatkinyerés':'AI data extraction','Töltse fel az útlevelet — a rendszer kiolvassa a nevet, útlevélszámot és állampolgárságot.':'Upload the passport — the system reads the name, passport number and citizenship.',
  // check step
  'Dokumentum-lista':'Document checklist','rendben':'ok','hiányzik':'missing','nincs':'none','Belső jegyzet':'Internal note','Megjegyzés (csak munkatársaknak)…':'Note (staff only)…','Gyanús eset':'Suspicious case','Egyezés-keresés a korábbi jelentkezések között (útlevélszám, név).':'Searches for matches among previous applications (passport number, name).','Ellenőrzés futtatása':'Run check','Újrafuttatás':'Re-run','Nincs egyezés':'No match','A jelentkezés egyedinek tűnik.':'The application appears unique.','Dokumentumok jóváhagyása':'Approve documents',
  // math step
  'Négy feladat, véletlenszerűen generálva. A megfeleléshez 4-ből legalább 3 helyes válasz kell.':'Four randomly generated tasks. You need at least 3 of 4 correct to pass.','Helyes':'Correct','Sikeres!':'Passed!','Új teszt':'New test','Beadás és pontozás':'Submit & grade','Egyenletrendszer':'System of equations','Kifejezés kiértékelése':'Evaluate expression','Másodfokú függvény':'Quadratic function','Logaritmus és szögfüggvény':'Logarithm & trigonometric function','Oldd meg a következő egyenletrendszert!':'Solve the following system of equations!','A matematika feltétel teljesült.':'The mathematics requirement is met.','Nem érte el a 3 pontot':'Did not reach 3 points','Próbálja újra — új feladatokat generálunk.':'Try again — we will generate new tasks.',
  // interview step
  'A foglaláskor automatikusan létrejön a Microsoft Teams meeting.':'A Microsoft Teams meeting is created automatically when you book.','Interjú lefoglalva':'Interview booked','Megerősítő e-mailt küldtünk.':'We have sent a confirmation email.','Időpont':'Time','Interjúztató':'Interviewer','Platform':'Platform','automatikus':'automatic','Időpont módosítása':'Change time',
  // letter step
  'Felvett szak':'Admitted program','Flintsign aláírás — később':'Flintsign signature — later','Nyomtatás':'Print','Levél kiállítása':'Issue letter','Folyamat lezárása':'Finish process','Tovább':'Next',
  // hub
  'Nincs aktív felvételi folyamat.':'No active admission process.','Biztosan törli ezt a folyamatot?':'Delete this process?','lépés':'steps','folyamat':'processes',
  // admin live status + detail
  'Dokumentumok jóváhagyva':'Documents approved','Ellenőrzés folyamatban':'Review in progress','Dokumentumok állapota':'Document status','felülvizsgálat alatt':'under review','Jóváhagyásra vár':'Awaiting approval','Az ügyintéző jóváhagyta a feltöltött dokumentumokat. Folytathatja a jelentkezést.':'The officer has approved your uploaded documents. You may continue your application.','A feltöltött dokumentumokat az ügyintéző ellenőrzi és hitelesíti. Kérjük, várjon a jóváhagyásra — az üzenetek között értesítjük.':'Your uploaded documents are being reviewed and verified by an officer. Please wait for approval — you will be notified in Messages.','A dokumentumok hitelességét egyetemi ügyintéző ellenőrzi és hagyja jóvá.':'Document authenticity is reviewed and approved by a university officer.','Azonos útlevélszám':'Same passport number','Azonos név':'Same name','Azonos e-mail':'Same email',
  'Felvételi folyamat — élő állapot':'Admission process — live status','Hol tart minden jelentkező és milyen dokumentum hiányzik még':'Where each applicant stands and which documents are still missing','Jelentkező':'Applicant','Szakok':'Programs','Folyamat':'Process','Hiányzó dokumentumok':'Missing documents','Állapot':'Status','Művelet':'Action','Minden feltöltve':'All uploaded','Megszakítva':'Cancelled','Részletek':'Details','Részletes nézet':'Detailed view','Felvéve · levél kiállítva':'Admitted · letter issued','Vissza a jelentkezésekhez':'Back to applications','Folyamat állapota':'Process status','Előnézet':'Preview','Letöltés':'Download','Hivatkozás':'Reference','Hivatkozva':'Referenced','hitelesítve':'verified','Jóváhagyás':'Approve','Visszavonás':'Revoke','Dokumentum hitelesítés':'Document verification','Minden dokumentum hitelesítve':'All documents verified','Üzenet a jelentkezőnek':'Message to the applicant','Üzenet írása a jelentkezőnek':'Write a message to the applicant','Tárgy':'Subject','Írd meg az üzenetet…':'Write your message…','Üzenet küldése':'Send message','Üzenet elküldve':'Message sent','A jelentkező az Üzenetek között látja.':'The applicant will see it under Messages.','A bal oldali dokumentumlistánál a „Hivatkozás" gombbal csatolhatsz fájlt az üzenethez.':'Attach a file to the message using the "Reference" button in the document list on the left.','Hivatkozott dokumentumok':'Referenced documents','Kinyert adatok (útlevél)':'Extracted data (passport)','Szimulált előnézet':'Simulated preview','opcionális':'optional','Nincs feltöltve':'Not uploaded','Akív Jelentkezések (Multi-Program)':'Active Applications (Multi-Program)','Aktív Jelentkezések (Multi-Program)':'Active Applications (Multi-Program)','Diák':'Student','Választott Szakok':'Selected programs','Ajánlások':'Recommendations','AI Státusz':'AI status',
  // messages
  'Felvételi folyamatokhoz kapcsolódó értesítések':'Notifications related to your admission processes','Összes megjelölése olvasottként':'Mark all as read','Felvételi Iroda':'Admissions Office','Feltételes felvételi levél kiállítva':'Conditional acceptance letter issued','Dokumentumok jóváhagyva — szintfelmérő következik':'Documents approved — placement test next','A dokumentumellenőrzés sikeres. Kérjük, töltse ki a matematika szintfelmérőt.':'Document check successful. Please complete the math placement test.','Hiányzó dokumentum':'Missing document','Kérjük, töltse fel a hiányzó dokumentumokat a folyamat folytatásához.':'Please upload the missing documents to continue the process.','UniPortal Rendszer':'UniPortal System','Üdvözöljük a felvételi rendszerben':'Welcome to the admissions system','Itt nyomon követheti az összes felvételi folyamatát és a kapcsolódó üzeneteket.':'Here you can track all your admission processes and related messages.','Üzenet a felvételi irodától':'Message from the Admissions Office',
};
const HU_EN_PHRASES = [
  [/Aktív jelentkezések/g,'Active applications'],[/Akív jelentkezések/g,'Active applications'],[/Új jelentkező/g,'New applicant'],[/\bMód\b/g,'Mode'],[/Felvételi folyamat ·/g,'Admission process ·'],[/(\d+)\s*\/\s*(\d+)\s*lépés/g,'$1/$2 steps'],[/(\d+)\s*lépés/g,'$1 steps'],[/(\d+)\s*folyamat\b/g,'$1 process(es)'],[/(\d+)%\s*biztos/g,'$1% confidence'],[/(\d+)\s*lehetséges egyezés/g,'$1 possible match(es)'],[/TESZT — helyes válasz:/g,'TEST — correct answer:'],[/Helyes:/g,'Correct:'],[/(\d+)\s*\/\s*(\d+)\s*helyes/g,'$1 / $2 correct'],[/(\d+)\s*\/\s*(\d+)\s*kötelező hitelesítve/g,'$1 / $2 required verified'],[/(\d+)\s*hiányzik/g,'$1 missing'],[/(\d+)\s*új\b/g,'$1 new'],[/EUR \/ szemeszter/g,'EUR / semester'],[/szemeszter/g,'semester'],[/szem\./g,'sem.'],[/Egyszerűsítsd, majd értékeld ki, ha/g,'Simplify, then evaluate if'],[/Mennyi/g,'What is'],[/Értékeld ki a következő kifejezést!/g,'Evaluate the following expression!'],[/Érték =/g,'Value ='],[/(\d+)\s*folyamat\b/g,'$1 process(es)'],[/(\d+)\s*\/\s*(\d+)\s*kötelező/g,'$1 / $2 required'],
];
(function setupI18n(){
  if ((localStorage.getItem('nje_lang') || 'hu') !== 'en') return;
  const SKIP = { INPUT:1, TEXTAREA:1, SCRIPT:1, STYLE:1, OPTION:1 };
  const translateText = (s) => {
    const trimmed = s.trim();
    if (!trimmed) return s;
    if (HU_EN[trimmed]) return s.replace(trimmed, HU_EN[trimmed]);
    let out = s, changed = false;
    for (const [re, rep] of HU_EN_PHRASES) { const n = out.replace(re, rep); if (n !== out) { out = n; changed = true; } }
    return changed ? out : s;
  };
  const translateOne = (n) => { if (!n || n.nodeType !== 3) return; if (n.parentNode && SKIP[n.parentNode.nodeName]) return; const t = translateText(n.nodeValue); if (t !== n.nodeValue) n.nodeValue = t; };
  const attrs = (root) => {
    if (!root || root.nodeType !== 1) return;
    if (root.hasAttribute && root.hasAttribute('placeholder')) { const k = (root.getAttribute('placeholder')||'').trim(); if (HU_EN[k]) root.setAttribute('placeholder', HU_EN[k]); }
    if (root.hasAttribute && root.hasAttribute('title')) { const k = (root.getAttribute('title')||'').trim(); if (HU_EN[k]) root.setAttribute('title', HU_EN[k]); }
    if (root.querySelectorAll) {
      root.querySelectorAll('[placeholder]').forEach(el => { const k = (el.getAttribute('placeholder')||'').trim(); if (HU_EN[k]) el.setAttribute('placeholder', HU_EN[k]); });
      root.querySelectorAll('[title]').forEach(el => { const k = (el.getAttribute('title')||'').trim(); if (HU_EN[k]) el.setAttribute('title', HU_EN[k]); });
    }
  };
  const walk = (root) => {
    if (!root) return;
    if (root.nodeType === 3) { translateOne(root); return; }
    if (root.nodeType !== 1 && root.nodeType !== 9 && root.nodeType !== 11) return;
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentNode && SKIP[n.parentNode.nodeName]) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
    const nodes = []; while (w.nextNode()) nodes.push(w.currentNode);
    nodes.forEach(n => { const t = translateText(n.nodeValue); if (t !== n.nodeValue) n.nodeValue = t; });
    attrs(root);
  };
  let obs = null;
  const OPTS = { childList: true, subtree: true, characterData: true };
  // Szinkron, kirajzolás előtti fordítás (microtask) — nincs magyar felvillanás, és a self-trigger loop kizárva.
  const handle = (records) => {
    if (!obs) return;
    obs.disconnect();
    try {
      for (const r of records) {
        if (r.type === 'characterData') translateOne(r.target);
        else if (r.addedNodes && r.addedNodes.length) r.addedNodes.forEach(n => walk(n));
      }
    } catch (e) {}
    obs.observe(document.body, OPTS);
  };
  const start = () => {
    walk(document.body);
    [150, 500, 1200].forEach(d => setTimeout(() => walk(document.body), d));
    obs = new MutationObserver(handle);
    obs.observe(document.body, OPTS);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
